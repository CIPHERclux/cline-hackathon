// The fast path (D74): one streamed model call with its own short system prompt, no agent loop,
// no session files, no tool definitions, no rule files. For the quick, stateless calls that sit
// in the user's way: the thinking filler, the zoom pass, "where is this control", and "is this
// walkthrough step done". It is still Cline: the same provider, models and sign-in as ClineCore,
// through the SDK's own provider client (@cline/llms via @cline/sdk), so §7.3's "reasoning only
// through Cline" holds. Planning, conversations and long answers stay on ClineCore sessions.
import { getProviderConfig, Llms, ProviderSettingsManager, resolveProviderApiKeyFromSettings } from "@cline/sdk";
import { classifySdkError, type ClassifiedError } from "./errors";
import type { CompleteRequest } from "./protocol";
import { resolveSlotModel } from "./routing";

// A quick call that hasn't started answering by then is a failure, not a wait (a voice UI can't
// sit on it).
const FIRST_CHUNK_TIMEOUT_MS = 30_000;
// No practical cap: models that reason first had replies cut in half by a small one (D86).
const DEFAULT_MAX_OUTPUT_TOKENS = 8192;

export type DirectCallbacks = {
    onText: (delta: string) => void;
    // `beforeFirstText`: nothing was streamed yet, so the caller may still try another path.
    onFailure: (failure: ClassifiedError, beforeFirstText: boolean) => void;
    onDone: () => void;
};

export async function runDirectCompletion(
    request: CompleteRequest,
    environment: Record<string, string | undefined>,
    signal: AbortSignal,
    callbacks: DirectCallbacks,
): Promise<void> {
    let streamedText = false;
    const firstChunkController = new AbortController();
    const forwardAbort = () => firstChunkController.abort(signal.reason);
    signal.addEventListener("abort", forwardAbort, { once: true });
    const firstChunkTimer = setTimeout(
        () => firstChunkController.abort(new Error("the model did not start answering in time")),
        FIRST_CHUNK_TIMEOUT_MS,
    );
    try {
        const model = resolveSlotModel(request.slot, environment, request.model);
        // The Cline provider's key is the persisted sign-in, exactly as ClineCore resolves it.
        const apiKey =
            model.apiKey ?? resolveProviderApiKeyFromSettings(new ProviderSettingsManager(), model.providerId);
        const handler = Llms.createHandler({
            providerId: model.providerId,
            modelId: model.modelId,
            apiKey,
            baseUrl: model.baseUrl ?? getProviderConfig(model.providerId)?.baseUrl,
            maxOutputTokens: request.maxTokens ?? DEFAULT_MAX_OUTPUT_TOKENS,
            abortSignal: firstChunkController.signal,
        } as any);
        const content: any[] = [{ type: "text", text: request.prompt }];
        for (const dataUrl of request.images ?? []) {
            const match = /^data:([^;]+);base64,(.*)$/s.exec(dataUrl);
            if (match) content.push({ type: "image", mediaType: match[1], data: match[2] });
        }
        for await (const chunk of handler.createMessage(request.system, [{ role: "user", content }])) {
            if (signal.aborted) return;
            if (chunk.type === "text" && chunk.text) {
                if (!streamedText) clearTimeout(firstChunkTimer);
                streamedText = true;
                callbacks.onText(chunk.text);
            } else if (chunk.type === "done" && chunk.success === false) {
                throw new Error(chunk.error ?? "the model stream failed");
            }
        }
        callbacks.onDone();
    } catch (error) {
        if (signal.aborted) return;
        const classified = classifySdkError(undefined, error);
        const status = (error as any)?.status ?? (error as any)?.statusCode;
        const failure: ClassifiedError =
            status === 401 || status === 403
                ? { kind: "auth", retryable: false, message: classified.message }
                : status === 429
                  ? { kind: "rate_limit", retryable: true, message: classified.message }
                  : classified;
        callbacks.onFailure(failure, !streamedText);
    } finally {
        clearTimeout(firstChunkTimer);
        signal.removeEventListener("abort", forwardAbort);
    }
}
