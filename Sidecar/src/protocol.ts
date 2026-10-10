// NDJSON protocol between the Swift app and tutor-engine (§7.3 "IPC protocol", proto 1).
// One JSON object per line on stdin (requests) and stdout (events). Logs go to stderr only.
// Every request ends with exactly one terminal event for its `re`: `done`, `error` or `pong`
// (and `usage` for the `usage` op) (D38).

export const PROTOCOL_VERSION = 1;

export type SlotName = "fast" | "teaching" | "grounding" | "deep";

export type StartRequest = {
    id: string;
    op: "start";
    session?: { kind?: string; tutor?: string };
    slot: SlotName;
    // Optional model id within the active profile's provider, overriding the slot's primary:
    // the Swift router's fallbacks (§7.4 rule 5) and the S02 per-model probes (D41).
    model?: string;
    prompt: string;
    images?: string[];
    context?: { skillPack?: string | null; marks?: string | null; memory?: string | null; doc?: string | null };
};

export type SendRequest = {
    id: string;
    op: "send";
    sessionId: string;
    // Optional model for this turn; the session keeps its history across the switch (§7.4
    // "Context across slots": update the session's model) (D45).
    model?: string;
    prompt: string;
    images?: string[];
    delivery?: "steer" | "queue";
};

// The fast path (D74): one stateless streamed call with its own system prompt, no agent loop.
// Answers with `session` (an id `abort` accepts), `text` deltas and one terminal event.
export type CompleteRequest = {
    id: string;
    op: "complete";
    slot: SlotName;
    model?: string;
    system: string;
    prompt: string;
    images?: string[];
    maxTokens?: number;
};

export type EngineRequest =
    | { id: string; op: "ping" }
    | CompleteRequest
    | { id: string; op: "prewarm"; slot?: SlotName }
    | StartRequest
    | SendRequest
    | { id: string; op: "abort"; sessionId: string }
    | { id: string; op: "tool_result"; callId: string; result: unknown }
    | { id: string; op: "usage"; sessionId: string };

export type ErrorKind = "auth" | "rate_limit" | "network" | "model" | "internal";

export type EngineEvent =
    | { re: string; ev: "pong"; proto: number }
    | { re: string; ev: "session"; sessionId: string; model: string }
    | { re: string; ev: "text"; delta: string }
    | { re: string; ev: "tool_call"; callId: string; name: string; input: unknown }
    | { re: string; ev: "usage"; inputTokens: number; outputTokens: number; costUSD: number }
    | { re: string; ev: "done"; status: "completed" | "aborted" | "steered" }
    | { re: string | null; ev: "error"; kind: ErrorKind; retryable: boolean; message: string };

const KNOWN_OPS = new Set(["ping", "prewarm", "start", "send", "abort", "tool_result", "usage", "complete"]);

export function parseRequestLine(line: string): EngineRequest | { invalid: string; id: string | null } {
    let parsed: any;
    try {
        parsed = JSON.parse(line);
    } catch {
        return { invalid: "request is not valid JSON", id: null };
    }
    const id = typeof parsed?.id === "string" ? parsed.id : null;
    if (id === null) return { invalid: "request has no string id", id: null };
    if (parsed.proto !== undefined && parsed.proto !== PROTOCOL_VERSION) {
        return { invalid: `unsupported proto ${parsed.proto}`, id };
    }
    if (!KNOWN_OPS.has(parsed.op)) return { invalid: `unknown op ${String(parsed.op)}`, id };
    return parsed as EngineRequest;
}
