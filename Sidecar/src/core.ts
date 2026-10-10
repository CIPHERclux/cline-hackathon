import { ClineCore } from "@cline/sdk";
import { classifyHttpStatus, classifySdkError, type ClassifiedError } from "./errors";
import { scrubScreenshotsFromMessagesFile } from "./privacy";

// §7.3 "Built-in tool policy": the tutor has no shell, no file read/write and no web fetch.
// Sessions also start with enableTools:false, so built-ins added in later SDK versions stay
// hidden too (D38). The contract test checks the provider request carries only our tools.
export const DISABLED_BUILTIN_TOOLS = [
    "run_commands",
    "editor",
    "apply_patch",
    "read_files",
    "search_codebase",
    "fetch_web_content",
    "spawn_agent",
    "team",
];

export const BUILTIN_TOOL_POLICIES = Object.fromEntries(
    DISABLED_BUILTIN_TOOLS.map((toolName) => [toolName, { enabled: false }]),
);

// The SDK attaches session config headers to every provider request; the fetch wrapper reads
// this one to know which session a failing request belongs to, and strips it before sending.
export const SESSION_HEADER = "x-chalk-session";

export type ProviderFailureListener = (sessionId: string | undefined, failure: ClassifiedError) => void;

// A provider that accepts the request but never starts answering would hang the turn forever
// (seen in S01: some Gemini free-tier models sat > 40 s). Response headers must arrive within
// this time; the stream itself may then run as long as it needs.
const DEFAULT_PROVIDER_RESPONSE_TIMEOUT_MS = 15_000;

// A rate limit or 5xx would otherwise be retried by the AI SDK and then the agent loop: 6
// attempts over ~62 s (measured in S01). A voice turn can't wait that long, so the first
// failure is reported at once and the Swift router decides on a fallback (§7.4 rule 5,
// §11.4 P-REGION) (D38).
function createProviderFetch(onProviderFailure: ProviderFailureListener): typeof fetch {
    const responseTimeoutMs = Number(process.env.CHALK_PROVIDER_RESPONSE_TIMEOUT_MS ?? DEFAULT_PROVIDER_RESPONSE_TIMEOUT_MS);
    const providerFetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
        const sessionId = headers.get(SESSION_HEADER) ?? undefined;
        headers.delete(SESSION_HEADER);

        // Our own controller, so the response timeout can cancel the request while the SDK's
        // signal (abort, shutdown) still reaches it for the whole stream.
        const requestController = new AbortController();
        const forwardSdkAbort = () => requestController.abort(init?.signal?.reason);
        if (init?.signal?.aborted) forwardSdkAbort();
        init?.signal?.addEventListener("abort", forwardSdkAbort, { once: true });
        let responseTimedOut = false;
        const responseTimer = setTimeout(() => {
            responseTimedOut = true;
            requestController.abort(new Error("provider response timeout"));
        }, responseTimeoutMs);

        let response: Response;
        const fetchStartedAt = performance.now();
        try {
            response = await fetch(input, { ...init, headers, signal: requestController.signal });
        } catch (error) {
            init?.signal?.removeEventListener("abort", forwardSdkAbort);
            if (process.env.CHALK_DEBUG_EVENTS) {
                console.error(`provider-fetch threw after ${(performance.now() - fetchStartedAt).toFixed(0)}ms timedOut=${responseTimedOut} sdkAborted=${init?.signal?.aborted} error=${String(error).slice(0, 300)}`);
            }
            if (responseTimedOut) {
                onProviderFailure(sessionId, {
                    kind: "model",
                    retryable: true,
                    message: `the model did not start answering within ${(responseTimeoutMs / 1000).toFixed(1)} s`,
                });
            } else if (!(init?.signal?.aborted ?? false)) {
                const message = error instanceof Error ? error.message : String(error);
                onProviderFailure(sessionId, { kind: "network", retryable: true, message });
            }
            throw error;
        } finally {
            clearTimeout(responseTimer);
        }
        if (process.env.CHALK_DEBUG_EVENTS) {
            const url = input instanceof Request ? input.url : String(input);
            console.error(`provider-fetch ${response.status} ${url.split("?")[0]} session=${sessionId ?? "-"}`);
        }
        if (response.status >= 400) {
            const bodyText = await response.clone().text().catch(() => "");
            onProviderFailure(sessionId, classifyHttpStatus(response.status, bodyText));
        }
        return response;
    };
    return providerFetch as typeof fetch;
}

export async function createEngineCore(onProviderFailure: ProviderFailureListener): Promise<ClineCore> {
    return ClineCore.create({
        clientName: "chalk-tutor-engine",
        // A fixed id instead of the SDK's default hardware-derived machine id; telemetry is off
        // anyway (D32).
        distinctId: "chalk-tutor-engine",
        // In-process runtime: no hub daemon, no remote host.
        backendMode: "local",
        // Scheduled agents are out of the demo cut (§4.7); keep the cron poller off.
        automation: false,
        toolPolicies: BUILTIN_TOOL_POLICIES,
        fetch: createProviderFetch(onProviderFailure),
        // The SDK calls this right after every write of a session's messages file (it is meant
        // for cloud upload). We use it to strip screenshots from the file at once: §10.1 says
        // they are never kept on disk (D39).
        messagesArtifactUploader: {
            uploadMessagesFile: async ({ path }) => {
                scrubScreenshotsFromMessagesFile(path);
            },
        },
    });
}

export { classifySdkError };
