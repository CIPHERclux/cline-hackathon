// S01 contract tests (§7.3 IPC, §11.1 "Sidecar" row, §15 S0). Every test runs the real engine
// process against the credit-free stub provider; nothing reaches a real model (D10).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineProcess } from "./engine-process";
import { startStubProvider, type StubProvider } from "./stub-provider";

const PROXY_TOOL_NAMES = ["create_flashcard"];
const SLOW_SCRIPT = Array.from({ length: 50 }, (_, index) => `{"type":"speak","group":"g1","text":"part ${index} "}\n`);

let stub: StubProvider;
let engine: EngineProcess;

beforeEach(() => {
    stub = startStubProvider();
    engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: stub.baseUrl });
});

afterEach(async () => {
    await engine.close();
    stub.stop();
    // Acceptance 7 (D32): nothing but the stub was contacted during any test.
    expect(engine.stderrText).not.toContain("NETGUARD");
});

const terminal = (requestId: string) => (event: any) =>
    event.re === requestId && (event.ev === "done" || event.ev === "error");

describe("protocol basics", () => {
    test("ping answers pong with the protocol version", async () => {
        engine.send({ id: "p1", op: "ping" });
        const pong = await engine.waitFor((event) => event.re === "p1");
        expect(pong.event).toEqual({ re: "p1", ev: "pong", proto: 1 });
    });

    test("malformed and unknown requests get an error, not a crash", async () => {
        engine.send({ id: "x1", op: "teleport" });
        engine.send({ id: "x2", op: "ping", proto: 2 });
        expect((await engine.waitFor((event) => event.re === "x1")).event).toMatchObject({ ev: "error", kind: "internal" });
        expect((await engine.waitFor((event) => event.re === "x2")).event).toMatchObject({ ev: "error", kind: "internal" });
        engine.send({ id: "p1", op: "ping" });
        await engine.waitFor((event) => event.re === "p1" && event.ev === "pong");
    });

    test("send to an unknown session is an error", async () => {
        engine.send({ id: "s1", op: "send", sessionId: "s_missing", prompt: "hi" });
        expect((await engine.waitFor(terminal("s1"))).event).toMatchObject({ ev: "error", kind: "internal" });
    });
});

describe("turns", () => {
    test("a session keeps its history across sends, separate from stateless fast-path calls", async () => {
        const stamp = { workflow_id: "workflow-test", state_revision: 1, evidence_revision: 2, generation: 3 };
        const proposal = JSON.stringify({ ...stamp, status: "decision", question: "Which format?", options: ["Web", "Editing"] });
        stub.enqueue({ kind: "stream", deltas: [proposal] });
        engine.send({ id: "a1", op: "start", slot: "teaching", prompt: "Return one stamped decision." });
        const session = await engine.waitFor((event) => event.re === "a1" && event.ev === "session");
        await engine.waitFor(terminal("a1"));
        const text = engine.events.filter(({ event }) => event.re === "a1" && event.ev === "text").map(({ event }) => event.delta).join("");
        expect(JSON.parse(text)).toMatchObject(stamp);
        stub.enqueue({ kind: "stream", deltas: ['{"recommendation":"Check the selected clip","uncertain":true}'] });
        engine.send({ id: "d1", op: "complete", slot: "teaching", system: "Diagnostic role; JSON only", prompt: "Blocker", maxTokens: 100 });
        await engine.waitFor(terminal("d1"));
        stub.enqueue({ kind: "stream", deltas: [JSON.stringify({ ...stamp, evidence_revision: 3, status: "complete", evidence: "Output visible" })] });
        engine.send({ id: "a2", op: "send", sessionId: session.event.sessionId, prompt: "User chose Web. Fresh evidence revision 3." });
        expect((await engine.waitFor(terminal("a2"))).event).toMatchObject({ ev: "done", status: "completed" });
        const guideRequest = stub.requests.at(-1)!.body;
        expect(JSON.stringify(guideRequest.messages)).toContain("User chose Web");
        expect(JSON.stringify(guideRequest.messages)).not.toContain("Diagnostic role");
        // send does not emit session again: hosts must retain the previous identifier.
        expect(engine.eventsFor("a2").some((event) => event.ev === "session")).toBe(false);
        stub.enqueue({ kind: "stream", deltas: ['{"status":"blocked","reason":"test"}'] });
        engine.send({ id: "a3", op: "send", sessionId: session.event.sessionId, prompt: "Same workflow, third turn." });
        await engine.waitFor(terminal("a3"));
        expect(JSON.stringify(stub.requests.at(-1)!.body.messages)).toContain("User chose Web");
        expect(JSON.stringify(stub.requests.at(-1)!.body.messages)).toContain("third turn");
    });

    test("1. start → session → text deltas → usage → done", async () => {
        stub.enqueue({ kind: "stream", deltas: ['{"type":"speak","group":"g1","text":"Good ', 'eye."}\n', '{"type":"end"}\n'] });
        engine.send({
            id: "r1",
            op: "start",
            session: { kind: "teach" },
            slot: "teaching",
            prompt: "why can they swap?",
            images: ["data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="],
            context: { marks: 'm1 "Σ"' },
        });
        await engine.waitFor(terminal("r1"));
        const events = engine.eventsFor("r1");
        expect(events[0]).toMatchObject({ ev: "session", model: "stub-teaching" });
        expect(events[0].sessionId).toMatch(/^s_/);
        const text = events.filter((event) => event.ev === "text").map((event) => event.delta).join("");
        expect(text).toBe('{"type":"speak","group":"g1","text":"Good eye."}\n{"type":"end"}\n');
        expect(events.some((event) => event.ev === "usage" && event.inputTokens === 120)).toBe(true);
        expect(events.at(-1)).toEqual({ re: "r1", ev: "done", status: "completed" });

        // The screenshot and the marks reach the model; nothing from the workspace does.
        const userMessage = stub.requests[0].body.messages.at(-1);
        expect(JSON.stringify(userMessage)).toContain('m1 \\"Σ\\"');
        expect(userMessage.content.some((part: any) => part.type === "image_url")).toBe(true);
        expect(stub.requests[0].body.messages).toHaveLength(2);
    });

    test("2. abort stops the stream within 100 ms", async () => {
        stub.enqueue({ kind: "stream", deltas: SLOW_SCRIPT, delayBetweenDeltasMs: 40 });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "explain" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor((event) => event.re === "r1" && event.ev === "text");

        const abortSentAt = engine.send({ id: "r2", op: "abort", sessionId: session.event.sessionId });
        const turnEnded = await engine.waitFor(terminal("r1"));
        const abortLatencyMs = turnEnded.receivedAt - abortSentAt;
        console.log(`abort → done(aborted): ${abortLatencyMs.toFixed(1)} ms`);
        expect(turnEnded.event).toEqual({ re: "r1", ev: "done", status: "aborted" });
        expect(abortLatencyMs).toBeLessThanOrEqual(100);
        expect((await engine.waitFor(terminal("r2"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(engine.eventsFor("r1").filter((event) => event.ev === "text").length).toBeLessThan(SLOW_SCRIPT.length);
    });

    test("3. a steer send reaches the running turn", async () => {
        stub.enqueue({ kind: "stream", deltas: SLOW_SCRIPT, delayBetweenDeltasMs: 40 });
        stub.enqueue({ kind: "stream", deltas: ['{"type":"speak","group":"g2","text":"Uniform means..."}\n', '{"type":"end"}\n'] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "explain" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor((event) => event.re === "r1" && event.ev === "text");

        engine.send({ id: "r2", op: "send", sessionId: session.event.sessionId, prompt: "wait, what is uniform?", delivery: "steer" });
        await engine.waitFor(terminal("r2"));
        expect(engine.eventsFor("r1").at(-1)).toEqual({ re: "r1", ev: "done", status: "steered" });
        const steeredText = engine.eventsFor("r2").filter((event) => event.ev === "text").map((event) => event.delta).join("");
        expect(steeredText).toContain("Uniform means");
        expect(engine.eventsFor("r2").at(-1)).toEqual({ re: "r2", ev: "done", status: "completed" });

        // The model saw its partial answer, then the learner's interruption, in one turn.
        const steeredRequest = stub.requests[1].body.messages;
        expect(steeredRequest.at(-2).role).toBe("assistant");
        expect(steeredRequest.at(-1)).toMatchObject({ role: "user" });
        expect(JSON.stringify(steeredRequest.at(-1))).toContain("wait, what is uniform?");
    });

    test("queued sends run in order after the current turn", async () => {
        stub.enqueue({ kind: "stream", deltas: SLOW_SCRIPT.slice(0, 5), delayBetweenDeltasMs: 30 });
        stub.enqueue({ kind: "stream", deltas: ["second answer"] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "first" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        engine.send({ id: "r2", op: "send", sessionId: session.event.sessionId, prompt: "and then?", delivery: "queue" });
        await engine.waitFor(terminal("r2"));
        expect(engine.eventsFor("r1").at(-1)).toMatchObject({ ev: "done", status: "completed" });
        expect(engine.eventsFor("r2").filter((event) => event.ev === "text").map((event) => event.delta).join("")).toBe("second answer");
        expect(JSON.stringify(stub.requests[1].body.messages.at(-1))).toContain("and then?");
    });

    test("start can name a model instead of the slot's primary (router fallback, D41)", async () => {
        stub.enqueue({ kind: "stream", deltas: ["ok"] });
        engine.send({ id: "r1", op: "start", slot: "teaching", model: "stub-fallback", prompt: "hi" });
        expect((await engine.waitFor((event) => event.re === "r1" && event.ev === "session")).event.model).toBe("stub-fallback");
        await engine.waitFor(terminal("r1"));
        expect(stub.requests[0].body.model).toBe("stub-fallback");
    });

    test("the rules (§7.5) reach the model in the system prompt", async () => {
        stub.enqueue({ kind: "stream", deltas: ["ok"] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "hi" });
        await engine.waitFor(terminal("r1"));
        const systemPrompt: string = stub.requests[0].body.messages[0].content;
        for (const marker of ["# Persona", "Teaching Script v1", "# Targets", "# Safety", "# Walkthroughs"]) expect(systemPrompt).toContain(marker);
    });

    test("send can switch the model and keeps the conversation (D45)", async () => {
        stub.enqueue({ kind: "stream", deltas: ["one"] });
        stub.enqueue({ kind: "stream", deltas: ["two"] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "q1" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor(terminal("r1"));
        engine.send({ id: "r2", op: "send", sessionId: session.event.sessionId, prompt: "short follow-up", model: "stub-fast" });
        expect((await engine.waitFor(terminal("r2"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(stub.requests[0].body.model).toBe("stub-teaching");
        expect(stub.requests[1].body.model).toBe("stub-fast");
        expect(stub.requests[1].body.messages.map((message: any) => message.role)).toEqual(["system", "user", "assistant", "user"]);
    });

    test("follow-up send on an idle session continues the conversation", async () => {
        stub.enqueue({ kind: "stream", deltas: ["one"] });
        stub.enqueue({ kind: "stream", deltas: ["two"] });
        engine.send({ id: "r1", op: "start", slot: "fast", prompt: "q1" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor(terminal("r1"));
        engine.send({ id: "r2", op: "send", sessionId: session.event.sessionId, prompt: "q2" });
        expect((await engine.waitFor(terminal("r2"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(stub.requests[1].body.messages.map((message: any) => message.role)).toEqual(["system", "user", "assistant", "user"]);
    });
});

describe("tools", () => {
    test("4. tool_call → tool_result round trip", async () => {
        stub.enqueue({
            kind: "stream",
            deltas: ['{"type":"speak","group":"g1","text":"Saving that."}\n'],
            toolCall: { name: "create_flashcard", arguments: { front: "What is a uniform distribution?", back: "Every outcome equally likely." } },
        });
        stub.enqueue({ kind: "stream", deltas: ['{"type":"end"}\n'] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "make me a card" });

        const toolCall = await engine.waitFor((event) => event.re === "r1" && event.ev === "tool_call");
        expect(toolCall.event).toMatchObject({ name: "create_flashcard", input: { front: "What is a uniform distribution?" } });
        engine.send({ id: "r2", op: "tool_result", callId: toolCall.event.callId, result: { ok: true, cardId: "fc_12" } });

        expect((await engine.waitFor(terminal("r2"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect((await engine.waitFor(terminal("r1"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(engine.eventsFor("r1").filter((event) => event.ev === "tool_call")).toHaveLength(1);
        const toolMessage = stub.requests[1].body.messages.at(-1);
        expect(toolMessage.role).toBe("tool");
        expect(toolMessage.content).toContain("fc_12");
    });

    test("5. the model sees none of the built-in tools", async () => {
        stub.enqueue({ kind: "stream", deltas: ['{"type":"end"}\n'] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "hi" });
        await engine.waitFor(terminal("r1"));
        const offeredTools = stub.requests[0].body.tools.map((tool: any) => tool.function.name).sort();
        expect(offeredTools).toEqual([...PROXY_TOOL_NAMES].sort());
    });

    test("a tool_result for an unknown call is an error", async () => {
        engine.send({ id: "r1", op: "tool_result", callId: "call_nope", result: {} });
        expect((await engine.waitFor(terminal("r1"))).event).toMatchObject({ ev: "error", kind: "internal" });
    });
});

describe("7. the fast path (D74)", () => {
    test("complete streams one direct call with its own system prompt, no tools, no rules", async () => {
        stub.enqueue({ kind: "stream", deltas: ['{"done":true}'] });
        engine.send({ id: "r1", op: "complete", slot: "fast", system: "Answer in JSON.", prompt: "is it done?" });
        expect((await engine.waitFor((event) => event.re === "r1" && event.ev === "session")).event.sessionId).toStartWith("d_");
        const done = await engine.waitFor(terminal("r1"));
        expect(done.event).toMatchObject({ ev: "done", status: "completed" });
        const text = engine.eventsFor("r1").filter((event) => event.ev === "text").map((event: any) => event.delta).join("");
        expect(text).toBe('{"done":true}');
        const body = stub.requests[0].body;
        expect(body.model).toBe("stub-fast");
        expect(JSON.stringify(body.messages)).toContain("Answer in JSON.");
        expect(JSON.stringify(body.messages)).not.toContain("# Persona");
        expect(body.tools ?? []).toHaveLength(0);
    });
});

describe("6. provider errors map to error kinds", () => {
    const cases = [
        { status: 401, body: '{"error":{"message":"invalid api key"}}', kind: "auth", retryable: false },
        { status: 403, body: '{"error":{"message":"not available in your region"}}', kind: "model", retryable: true },
        { status: 429, body: '{"error":{"message":"rate limited"}}', kind: "rate_limit", retryable: true },
        { status: 500, body: '{"error":{"message":"upstream exploded"}}', kind: "model", retryable: true },
        // A model the provider doesn't serve falls back to the next one (D73).
        { status: 404, body: '{"error":{"message":"model not found"}}', kind: "model", retryable: true },
        { status: 400, body: '{"error":{"message":"bad request: prompt too long"}}', kind: "model", retryable: false },
    ];
    for (const errorCase of cases) {
        test(`HTTP ${errorCase.status} → ${errorCase.kind} within 1 s (no 62 s SDK retry chain)`, async () => {
            for (let attempt = 0; attempt < 10; attempt++) stub.enqueue({ kind: "error", status: errorCase.status, body: errorCase.body });
            const sentAt = engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "hi" });
            const failure = await engine.waitFor(terminal("r1"));
            expect(failure.event).toMatchObject({ ev: "error", kind: errorCase.kind, retryable: errorCase.retryable });
            expect(failure.receivedAt - sentAt).toBeLessThan(1_000);
            // Exactly one terminal event for the request.
            await Bun.sleep(150);
            expect(engine.eventsFor("r1").filter((event) => event.ev === "done" || event.ev === "error")).toHaveLength(1);
        });
    }

    test("a provider that never answers → model error after the response timeout", async () => {
        await engine.close();
        engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: stub.baseUrl, CHALK_PROVIDER_RESPONSE_TIMEOUT_MS: "300" });
        stub.enqueue({ kind: "hang" });
        const sentAt = engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "hi" });
        const failure = await engine.waitFor(terminal("r1"));
        expect(failure.event).toMatchObject({ ev: "error", kind: "model", retryable: true });
        expect(failure.receivedAt - sentAt).toBeLessThan(1_000);
        await Bun.sleep(150);
        expect(engine.eventsFor("r1").filter((event) => event.ev === "done" || event.ev === "error")).toHaveLength(1);
        expect(stub.requests).toHaveLength(1);
    });

    test("the response timeout never cuts off an answer that is already streaming", async () => {
        await engine.close();
        engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: stub.baseUrl, CHALK_PROVIDER_RESPONSE_TIMEOUT_MS: "300" });
        stub.enqueue({ kind: "stream", deltas: SLOW_SCRIPT.slice(0, 30), delayBetweenDeltasMs: 50 });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "long answer" });
        expect((await engine.waitFor(terminal("r1"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(engine.eventsFor("r1").filter((event) => event.ev === "text")).toHaveLength(30);
    });

    test("unreachable provider → network", async () => {
        await engine.close();
        engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: "http://127.0.0.1:9/v1" });
        engine.send({ id: "r1", op: "start", slot: "fast", prompt: "hi" });
        expect((await engine.waitFor(terminal("r1"))).event).toMatchObject({ ev: "error", kind: "network", retryable: true });
    });
});

describe("screenshot privacy (§7.4, §10.1, D39)", () => {
    const RED_PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
    const BLUE_PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC";

    test("only the current screen reaches the model, and no screenshot stays on disk", async () => {
        for (const answer of ["first", "second", "third"]) stub.enqueue({ kind: "stream", deltas: [answer] });
        engine.send({ id: "r1", op: "start", slot: "teaching", prompt: "what is this?", images: [`data:image/png;base64,${RED_PIXEL}`] });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor(terminal("r1"));
        const sessionId = session.event.sessionId;

        // A follow-up without a new capture is still about the same screen.
        engine.send({ id: "r2", op: "send", sessionId, prompt: "and that part?" });
        await engine.waitFor(terminal("r2"));
        expect(JSON.stringify(stub.requests[1].body)).toContain(RED_PIXEL);

        // A new capture replaces the old screen in what the model sees.
        engine.send({ id: "r3", op: "send", sessionId, prompt: "now this one", images: [`data:image/png;base64,${BLUE_PIXEL}`] });
        await engine.waitFor(terminal("r3"));
        const thirdRequest = JSON.stringify(stub.requests[2].body);
        expect(thirdRequest).toContain(BLUE_PIXEL);
        expect(thirdRequest).not.toContain(RED_PIXEL);
        expect(thirdRequest).toContain("[earlier screenshot removed]");

        // Nothing under CLINE_DIR holds image data; files are owner-only.
        const files: string[] = [];
        const walk = (directory: string) => {
            for (const entry of readdirSync(directory, { withFileTypes: true })) {
                const path = join(directory, entry.name);
                if (entry.isDirectory()) walk(path);
                else files.push(path);
            }
        };
        walk(engine.clineDirectory);
        const sessionFiles = files.filter((path) => path.includes(sessionId));
        expect(sessionFiles.length).toBeGreaterThan(0);
        for (const path of files) {
            const bytes = readFileSync(path);
            expect(bytes.includes(RED_PIXEL)).toBe(false);
            expect(bytes.includes(BLUE_PIXEL)).toBe(false);
            expect((statSync(path).mode & 0o077).toString(8)).toBe("0");
        }
    });
});

describe("screenshot crash recovery (D39)", () => {
    test("a screenshot left on disk by a crash is scrubbed at the next launch", async () => {
        await engine.close();
        const clineDirectory = mkdtempSync(join(tmpdir(), "chalk-cline-crash-"));
        const sessionDirectory = join(clineDirectory, "data", "sessions", "s_crashed");
        mkdirSync(sessionDirectory, { recursive: true });
        const messagesFile = join(sessionDirectory, "s_crashed.messages.json");
        writeFileSync(messagesFile, JSON.stringify({ messages: [{ role: "user", content: [{ type: "text", text: "look" }, { type: "image", data: "LEFTOVERPIXELS", mediaType: "image/png" }] }] }));

        engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: stub.baseUrl, CLINE_DIR: clineDirectory });
        engine.send({ id: "p1", op: "ping" });
        await engine.waitFor((event) => event.re === "p1");
        const scrubbed = readFileSync(messagesFile, "utf8");
        expect(scrubbed).not.toContain("LEFTOVERPIXELS");
        expect(scrubbed).toContain("look");
    });
});

describe("7. network guard", () => {
    test.skipIf(Boolean(process.env.CHALK_ENGINE_BINARY))("the guard really catches a non-loopback connection (so its silence above means something)", async () => {
        await engine.close();
        // TEST-NET-1 (RFC 5737): never routable, so nothing leaves the Mac even if the guard failed.
        engine = EngineProcess.launch({ CHALK_STUB_BASE_URL: "http://192.0.2.1/v1" });
        engine.send({ id: "r1", op: "start", slot: "fast", prompt: "hi" });
        await engine.waitFor(terminal("r1"));
        expect(engine.stderrText).toContain("NETGUARD blocked http://192.0.2.1/v1/chat/completions");
        engine.stderrText = "";
    });
});

describe("usage and prewarm", () => {
    test("usage reports accumulated tokens for a session", async () => {
        stub.enqueue({ kind: "stream", deltas: ["a"] });
        engine.send({ id: "r1", op: "start", slot: "fast", prompt: "hi" });
        const session = await engine.waitFor((event) => event.re === "r1" && event.ev === "session");
        await engine.waitFor(terminal("r1"));
        engine.send({ id: "r2", op: "usage", sessionId: session.event.sessionId });
        expect((await engine.waitFor((event) => event.re === "r2")).event).toEqual({
            re: "r2",
            ev: "usage",
            inputTokens: 120,
            outputTokens: 30,
            costUSD: 0,
        });
    });

    test("prewarm makes one tiny request on the teaching slot", async () => {
        stub.enqueue({ kind: "stream", deltas: ["OK"] });
        engine.send({ id: "w1", op: "prewarm" });
        expect((await engine.waitFor(terminal("w1"))).event).toMatchObject({ ev: "done", status: "completed" });
        expect(stub.requests[0].body.model).toBe("stub-teaching");
    });
});
