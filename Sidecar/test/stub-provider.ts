// Credit-free stand-in for a model provider (§11.1 "a mock Cline provider (SDK `baseUrl` to a
// local stub)"). It speaks the OpenAI-compatible chat-completions streaming format, which the
// SDK's `openai-compatible` provider talks to. Tests queue one scripted reply per model request
// and inspect what the SDK sent (tools, messages) to prove built-ins are hidden (§7.3).

export type StubToolCall = { name: string; arguments: Record<string, unknown> };

export type StubReply =
    | {
          kind: "stream";
          // Each entry is streamed as one content delta. Teaching Script NDJSON lines go here.
          deltas: string[];
          delayBetweenDeltasMs?: number;
          // Wait before the first delta (a slow first token, e.g. for crash-and-retry tests).
          initialDelayMs?: number;
          toolCall?: StubToolCall;
      }
    | { kind: "error"; status: number; body: string }
    // Accepts the request and never answers (a provider that hangs before the first byte).
    | { kind: "hang" };

export type RecordedRequest = {
    path: string;
    body: any;
    receivedAt: number;
    // Set when the client hung up before the stub finished streaming (abort measurement).
    clientDisconnectedAt?: number;
};

export type StubProvider = {
    baseUrl: string;
    requests: RecordedRequest[];
    enqueue(reply: StubReply): void;
    stop(): void;
};

const ENCODER = new TextEncoder();

function sseChunk(payload: unknown): Uint8Array {
    return ENCODER.encode(`data: ${JSON.stringify(payload)}\n\n`);
}

export function startStubProvider(): StubProvider {
    const pendingReplies: StubReply[] = [];
    const requests: RecordedRequest[] = [];

    const server = Bun.serve({
        port: 0,
        hostname: "127.0.0.1",
        idleTimeout: 0,
        async fetch(request) {
            const url = new URL(request.url);
            if (request.method !== "POST" || !url.pathname.endsWith("/chat/completions")) {
                return new Response(JSON.stringify({ data: [] }), {
                    headers: { "content-type": "application/json" },
                });
            }
            const recorded: RecordedRequest = {
                path: url.pathname,
                body: await request.json(),
                receivedAt: performance.now(),
            };
            requests.push(recorded);

            const reply: StubReply = pendingReplies.shift() ?? {
                kind: "stream",
                deltas: ['{"type":"end"}\n'],
            };
            if (reply.kind === "hang") {
                await new Promise<void>((resolve) => request.signal.addEventListener("abort", () => resolve(), { once: true }));
                recorded.clientDisconnectedAt = performance.now();
                return new Response(null, { status: 499 });
            }
            if (reply.kind === "error") {
                return new Response(reply.body, {
                    status: reply.status,
                    headers: { "content-type": "application/json" },
                });
            }

            const completionId = `chatcmpl-stub-${requests.length}`;
            const model = recorded.body?.model ?? "stub-model";
            const stream = new ReadableStream<Uint8Array>({
                async start(controller) {
                    const send = (delta: Record<string, unknown>, finishReason: string | null = null) =>
                        controller.enqueue(
                            sseChunk({
                                id: completionId,
                                object: "chat.completion.chunk",
                                created: Math.floor(Date.now() / 1000),
                                model,
                                choices: [{ index: 0, delta, finish_reason: finishReason }],
                            }),
                        );
                    try {
                        send({ role: "assistant", content: "" });
                        if (reply.initialDelayMs) await Bun.sleep(reply.initialDelayMs);
                        for (const delta of reply.deltas) {
                            if (request.signal.aborted) throw new Error("client disconnected");
                            send({ content: delta });
                            if (reply.delayBetweenDeltasMs) await Bun.sleep(reply.delayBetweenDeltasMs);
                        }
                        if (reply.toolCall) {
                            send({
                                tool_calls: [
                                    {
                                        index: 0,
                                        id: `call_stub_${requests.length}`,
                                        type: "function",
                                        function: {
                                            name: reply.toolCall.name,
                                            arguments: JSON.stringify(reply.toolCall.arguments),
                                        },
                                    },
                                ],
                            });
                        }
                        send({}, reply.toolCall ? "tool_calls" : "stop");
                        controller.enqueue(
                            sseChunk({
                                id: completionId,
                                object: "chat.completion.chunk",
                                created: Math.floor(Date.now() / 1000),
                                model,
                                choices: [],
                                usage: { prompt_tokens: 120, completion_tokens: 30, total_tokens: 150 },
                            }),
                        );
                        controller.enqueue(ENCODER.encode("data: [DONE]\n\n"));
                        controller.close();
                    } catch {
                        recorded.clientDisconnectedAt = performance.now();
                        try {
                            controller.close();
                        } catch {}
                    }
                },
                cancel() {
                    recorded.clientDisconnectedAt ??= performance.now();
                },
            });
            return new Response(stream, {
                headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
            });
        },
    });

    return {
        baseUrl: `http://127.0.0.1:${server.port}/v1`,
        requests,
        enqueue: (reply) => pendingReplies.push(reply),
        stop: () => server.stop(true),
    };
}
