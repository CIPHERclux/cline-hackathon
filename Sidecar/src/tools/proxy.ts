import { createTool, type AgentTool } from "@cline/sdk";

// §7.3 "Custom tools": every tool is executed by Swift. The sidecar only forwards the call
// (`tool_call`) and waits for Swift's `tool_result`, so it never touches the screen, disk or DB.
// Demo set only (§4.7): create_flashcard. Walkthrough progress is script lines, not tools: the
// fast model called advance_step / mark_step_done instead of writing them, costing a round trip
// each and losing the verdict (D73).

export type ToolCallForwarder = (call: {
    sessionId: string | undefined;
    callId: string;
    name: string;
    input: unknown;
}) => void;

// Swift answers quickly (a DB insert or a state flip). If it never answers, the model gets an
// error result instead of the turn hanging.
const TOOL_RESULT_TIMEOUT_MS = 20_000;

export class PendingToolCalls {
    private readonly waitersByCallId = new Map<string, (result: unknown) => void>();

    waitFor(callId: string, signal: AbortSignal | undefined): Promise<unknown> {
        return new Promise((resolve) => {
            const finish = (result: unknown) => {
                clearTimeout(timeout);
                signal?.removeEventListener("abort", onAbort);
                this.waitersByCallId.delete(callId);
                resolve(result);
            };
            const timeout = setTimeout(
                () => finish({ ok: false, error: "the app did not answer this tool call in time" }),
                TOOL_RESULT_TIMEOUT_MS,
            );
            const onAbort = () => finish({ ok: false, error: "turn aborted" });
            signal?.addEventListener("abort", onAbort, { once: true });
            this.waitersByCallId.set(callId, finish);
        });
    }

    // Returns false when no tool call with that id is waiting (late or duplicate result).
    resolve(callId: string, result: unknown): boolean {
        const waiter = this.waitersByCallId.get(callId);
        if (!waiter) return false;
        waiter(result);
        return true;
    }
}

export function createProxyTools(forward: ToolCallForwarder, pending: PendingToolCalls): AgentTool[] {
    const proxyTool = (name: string, description: string, inputSchema: Record<string, unknown>) =>
        createTool<unknown, unknown>({
            name,
            description,
            inputSchema,
            // The SDK default (retryable, 3 retries) would re-run execute and send Swift a
            // duplicate tool_call, e.g. two flashcards.
            retryable: false,
            maxRetries: 0,
            timeoutMs: TOOL_RESULT_TIMEOUT_MS + 1_000,
            execute: async (input, context) => {
                const callId = context.toolCallId ?? `call_${crypto.randomUUID()}`;
                const result = pending.waitFor(callId, context.signal);
                forward({ sessionId: context.sessionId, callId, name, input });
                return result;
            },
        }) as AgentTool;

    return [
        proxyTool("create_flashcard", "Save a flashcard for the learner to review later.", {
            type: "object",
            properties: {
                front: { type: "string" },
                back: { type: "string" },
                tags: { type: "array", items: { type: "string" } },
                attachCrop: { type: "boolean", description: "Attach the current screen crop" },
            },
            required: ["front", "back"],
        }),
    ];
}

export const PROXY_TOOL_NAMES = ["create_flashcard"];
