import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type { ClineCore } from "@cline/sdk";
import { BUILTIN_TOOL_POLICIES, classifySdkError, createEngineCore, SESSION_HEADER } from "./core";
import type { ClassifiedError } from "./errors";
import { dropEarlierScreenshots, scrubScreenshotsFromAllSessionFiles } from "./privacy";
import { installTeacherRules } from "./rules";
import { runDirectCompletion } from "./direct";
import type { CompleteRequest, EngineEvent, EngineRequest, SendRequest, SlotName, StartRequest } from "./protocol";
import { resolveSlotModel } from "./routing";
import { createProxyTools, PendingToolCalls } from "./tools/proxy";

// Short base persona only; the rules live in .clinerules and skills (§7.5).
const BASE_SYSTEM_PROMPT =
    "You are Chalk, a friendly guide who answers questions about what is on the user's screen " +
    "out loud while pointing and drawing on it, and walks them through tasks step by step. " +
    "Keep spoken sentences short and natural.";

type SessionState = {
    sessionId: string;
    modelId: string;
    // The request whose `re` receives this session's streamed events right now.
    activeRequestId: string;
    // True once the active request got its terminal event, so late SDK events are dropped.
    activeRequestFinished: boolean;
    turnRunning: boolean;
    // Steer prompts handed to the SDK, waiting for its `pending_prompt_submitted` (FIFO).
    steerRequestIdsAwaitingSubmit: string[];
    // `delivery:"queue"` prompts. The SDK's own queue only drains when the host prods the
    // session (measured in S01), so the engine sends the next one itself when a turn ends (D38).
    queuedSends: SendRequest[];
};

export class Engine {
    private readonly sessions = new Map<string, SessionState>();
    private readonly pendingToolCalls = new PendingToolCalls();
    // Fast-path calls in flight, by the id their `session` event gave out (`abort` takes it).
    private readonly directCalls = new Map<string, AbortController>();
    private readonly corePromise: Promise<ClineCore>;
    private readonly emptyWorkspaceDirectory: string;

    constructor(
        private readonly emit: (event: EngineEvent) => void,
        private readonly environment: Record<string, string | undefined>,
        clineDirectory: string,
    ) {
        // A crash between the SDK writing a turn and our scrub could leave a screenshot on
        // disk; clear any such leftovers before taking new work (D39).
        scrubScreenshotsFromAllSessionFiles(clineDirectory);
        installTeacherRules(clineDirectory);
        // §7.3 Launch: sessions run with cwd set to an empty sandbox dir.
        this.emptyWorkspaceDirectory = join(clineDirectory, "empty-workspace");
        mkdirSync(this.emptyWorkspaceDirectory, { recursive: true });
        // §7.3 Warm-up: create the core at launch, but answer `ping` without waiting for it.
        this.corePromise = createEngineCore((sessionId, failure) => this.handleProviderFailure(sessionId, failure));
        this.corePromise.then((core) => core.subscribe((event) => this.handleCoreEvent(event)));
    }

    async handle(request: EngineRequest): Promise<void> {
        try {
            switch (request.op) {
                case "ping":
                    this.emit({ re: request.id, ev: "pong", proto: 1 });
                    return;
                case "prewarm":
                    return await this.prewarm(request.id, request.slot ?? "teaching");
                case "start":
                    return await this.start(request);
                case "complete":
                    return await this.complete(request);
                case "send":
                    return await this.send(request);
                case "abort":
                    return await this.abort(request.id, request.sessionId);
                case "tool_result":
                    if (!this.pendingToolCalls.resolve(request.callId, request.result)) {
                        return this.emitError(request.id, { kind: "internal", retryable: false, message: `no pending tool call ${request.callId}` });
                    }
                    this.emit({ re: request.id, ev: "done", status: "completed" });
                    return;
                case "usage":
                    return await this.usage(request.id, request.sessionId);
            }
        } catch (error) {
            this.emitError(request.id, { kind: "internal", retryable: false, message: error instanceof Error ? error.message : String(error) });
        }
    }

    async dispose(): Promise<void> {
        const core = await this.corePromise.catch(() => undefined);
        await core?.dispose("tutor-engine shutting down");
    }

    private sessionConfig(sessionId: string, slot: SlotName, modelOverride?: string) {
        const model = resolveSlotModel(slot, this.environment, modelOverride);
        const forwardToolCall = (call: { sessionId: string | undefined; callId: string; name: string; input: unknown }) => {
            const session = this.sessions.get(call.sessionId ?? sessionId);
            if (!session) return;
            this.emit({ re: session.activeRequestId, ev: "tool_call", callId: call.callId, name: call.name, input: call.input });
        };
        return {
            model,
            config: {
                ...model,
                sessionId,
                systemPrompt: BASE_SYSTEM_PROMPT,
                cwd: this.emptyWorkspaceDirectory,
                headers: { [SESSION_HEADER]: sessionId },
                enableTools: false,
                enableSpawnAgent: false,
                enableAgentTeams: false,
                extraTools: createProxyTools(forwardToolCall, this.pendingToolCalls),
                hooks: {
                    // §7.4: only the current screen goes to the model; earlier screenshots are
                    // replaced by a placeholder in the request (D39).
                    beforeModel: ({ request }: { request: { messages: readonly any[] } }) => {
                        const messages = dropEarlierScreenshots(request.messages);
                        return messages ? { messages } : undefined;
                    },
                },
            },
        };
    }

    // D74: the fast path. If the direct call can't start for a reason another path might not
    // share (not auth, not a rate limit), the same prompt runs as a one-shot ClineCore session,
    // so a quick call never breaks outright.
    private async complete(request: CompleteRequest): Promise<void> {
        const directId = `d_${crypto.randomUUID()}`;
        const controller = new AbortController();
        this.directCalls.set(directId, controller);
        this.emit({ re: request.id, ev: "session", sessionId: directId, model: request.model ?? request.slot });
        let fellBack = false;
        await runDirectCompletion(request, this.environment, controller.signal, {
            onText: (delta) => this.emit({ re: request.id, ev: "text", delta }),
            onDone: () => this.emit({ re: request.id, ev: "done", status: "completed" }),
            onFailure: (failure, beforeFirstText) => {
                if (beforeFirstText && failure.kind !== "auth" && failure.kind !== "rate_limit") {
                    if (process.env.CHALK_DEBUG_EVENTS) console.error(`direct call fell back: ${failure.message}`);
                    fellBack = true;
                    return;
                }
                this.emitError(request.id, failure);
            },
        });
        this.directCalls.delete(directId);
        if (controller.signal.aborted) {
            this.emit({ re: request.id, ev: "done", status: "aborted" });
            return;
        }
        if (fellBack) {
            await this.start({
                id: request.id,
                op: "start",
                slot: request.slot,
                model: request.model,
                prompt: `${request.system}\n\n${request.prompt}`,
                images: request.images,
            });
        }
    }

    private async start(request: StartRequest): Promise<void> {
        const core = await this.corePromise;
        const sessionId = `s_${crypto.randomUUID()}`;
        const { model, config } = this.sessionConfig(sessionId, request.slot, request.model);
        const session: SessionState = {
            sessionId,
            modelId: model.modelId,
            activeRequestId: request.id,
            activeRequestFinished: false,
            turnRunning: true,
            steerRequestIdsAwaitingSubmit: [],
            queuedSends: [],
        };
        this.sessions.set(sessionId, session);
        this.emit({ re: request.id, ev: "session", sessionId, model: model.modelId });
        await this.runTurn(session, () =>
            core.start({
                config,
                prompt: promptWithContext(request),
                userImages: request.images,
                // Interactive keeps the session alive for follow-up sends and steering.
                interactive: true,
                sessionMetadata: { kind: request.session?.kind, tutor: request.session?.tutor },
                toolPolicies: BUILTIN_TOOL_POLICIES,
            }),
        );
    }

    private async send(request: SendRequest): Promise<void> {
        const core = await this.corePromise;
        const session = this.sessions.get(request.sessionId);
        if (!session) {
            return this.emitError(request.id, { kind: "internal", retryable: false, message: `unknown session ${request.sessionId}` });
        }
        if (!session.turnRunning) {
            this.activateRequest(session, request.id);
            if (request.model && request.model !== session.modelId) {
                await core.updateSessionModel(session.sessionId, request.model);
                session.modelId = request.model;
            }
            await this.runTurn(session, () =>
                core.send({ sessionId: session.sessionId, prompt: request.prompt, userImages: request.images }),
            );
            return;
        }
        if (request.delivery === "steer") {
            // §7.6 Barge-in: redirect the running turn. The partial answer stays in history and
            // the SDK continues from the learner's interruption.
            session.steerRequestIdsAwaitingSubmit.push(request.id);
            await core.send({ sessionId: session.sessionId, prompt: request.prompt, userImages: request.images, delivery: "steer" });
            return;
        }
        session.queuedSends.push(request);
    }

    private async runTurn(session: SessionState, runSdkTurn: () => Promise<unknown>): Promise<void> {
        session.turnRunning = true;
        try {
            await runSdkTurn();
        } catch (error) {
            this.finishActiveRequestWithError(session, {
                kind: "internal",
                retryable: false,
                message: error instanceof Error ? error.message : String(error),
            });
        } finally {
            session.turnRunning = false;
        }
        const nextQueuedSend = session.queuedSends.shift();
        if (nextQueuedSend) await this.send(nextQueuedSend);
    }

    private async abort(requestId: string, sessionId: string): Promise<void> {
        const directCall = this.directCalls.get(sessionId);
        if (directCall) {
            directCall.abort(new Error("interrupted"));
            this.emit({ re: requestId, ev: "done", status: "completed" });
            return;
        }
        const core = await this.corePromise;
        const session = this.sessions.get(sessionId);
        if (session) {
            // Queued prompts never started; end them so every request id gets a terminal event.
            for (const queuedSend of session.queuedSends.splice(0)) {
                this.emit({ re: queuedSend.id, ev: "done", status: "aborted" });
            }
            if (session.turnRunning) await core.abort(sessionId, "learner interrupted");
        }
        this.emit({ re: requestId, ev: "done", status: "completed" });
    }

    private async usage(requestId: string, sessionId: string): Promise<void> {
        const core = await this.corePromise;
        const summary = await core.getAccumulatedUsage(sessionId);
        const usage = summary?.aggregateUsage ?? summary?.usage;
        this.emit({
            re: requestId,
            ev: "usage",
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            costUSD: usage?.totalCost ?? 0,
        });
    }

    // §7.3 Warm-up: a 1-token request opens TLS and auth before the learner's first question.
    private async prewarm(requestId: string, slot: SlotName): Promise<void> {
        const core = await this.corePromise;
        const sessionId = `prewarm_${crypto.randomUUID()}`;
        const { model, config } = this.sessionConfig(sessionId, slot);
        const session: SessionState = {
            sessionId,
            modelId: model.modelId,
            activeRequestId: requestId,
            activeRequestFinished: false,
            turnRunning: true,
            steerRequestIdsAwaitingSubmit: [],
            queuedSends: [],
        };
        this.sessions.set(sessionId, session);
        try {
            await this.runTurn(session, () =>
                core.start({ config: { ...config, maxTokensPerTurn: 1 }, prompt: "Reply with OK.", toolPolicies: BUILTIN_TOOL_POLICIES }),
            );
        } finally {
            this.sessions.delete(sessionId);
            await core.delete(sessionId).catch(() => false);
        }
    }

    private handleCoreEvent(event: any): void {
        // Diagnostics only, to stderr (stdout is the protocol). Off unless asked for.
        if (this.environment.CHALK_DEBUG_EVENTS) console.error(`sdk-event ${JSON.stringify(event).slice(0, 800)}`);
        const sessionId: string | undefined = event?.payload?.sessionId;
        const session = sessionId ? this.sessions.get(sessionId) : undefined;
        if (!session) return;

        if (event.type === "pending_prompt_submitted" && event.payload.delivery === "steer") {
            const steerRequestId = session.steerRequestIdsAwaitingSubmit.shift();
            if (!steerRequestId) return;
            if (!session.activeRequestFinished) this.emit({ re: session.activeRequestId, ev: "done", status: "steered" });
            this.activateRequest(session, steerRequestId);
            return;
        }
        if (event.type !== "agent_event" || event.payload.teamRole === "teammate") return;
        if (session.activeRequestFinished) return;

        const agentEvent = event.payload.event;
        const re = session.activeRequestId;
        switch (agentEvent.type) {
            case "content_start":
                if (agentEvent.contentType === "text" && agentEvent.text) this.emit({ re, ev: "text", delta: agentEvent.text });
                return;
            case "usage":
                this.emit({ re, ev: "usage", inputTokens: agentEvent.inputTokens ?? 0, outputTokens: agentEvent.outputTokens ?? 0, costUSD: agentEvent.cost ?? 0 });
                return;
            case "error":
                this.finishActiveRequestWithError(session, classifySdkError(agentEvent.errorClass, agentEvent.error));
                return;
            case "done":
                if (agentEvent.reason === "completed" || agentEvent.reason === "aborted") {
                    session.activeRequestFinished = true;
                    this.emit({ re, ev: "done", status: agentEvent.reason });
                } else {
                    this.finishActiveRequestWithError(session, { kind: "internal", retryable: false, message: `turn ended: ${agentEvent.reason}` });
                }
                return;
        }
    }

    private handleProviderFailure(sessionId: string | undefined, failure: ClassifiedError): void {
        const session = sessionId ? this.sessions.get(sessionId) : undefined;
        if (!session || session.activeRequestFinished) return;
        this.finishActiveRequestWithError(session, failure);
        // Stop the SDK's retry chain; the Swift router owns fallback (§7.4) (D38).
        void this.corePromise.then((core) => core.abort(session.sessionId, "provider failure"));
    }

    private activateRequest(session: SessionState, requestId: string): void {
        session.activeRequestId = requestId;
        session.activeRequestFinished = false;
    }

    private finishActiveRequestWithError(session: SessionState, failure: ClassifiedError): void {
        if (session.activeRequestFinished) return;
        session.activeRequestFinished = true;
        this.emitError(session.activeRequestId, failure);
    }

    private emitError(requestId: string | null, failure: ClassifiedError): void {
        this.emit({ re: requestId, ev: "error", kind: failure.kind, retryable: failure.retryable, message: failure.message });
    }
}

// Until the teaching plugin injects context in `before_agent_start` (§7.5, slice S11), the
// marks list and other context ride along as a plain text block ahead of the question.
function promptWithContext(request: StartRequest): string {
    const context = request.context;
    if (!context) return request.prompt;
    const contextLines = [
        context.skillPack ? `App: ${context.skillPack}` : null,
        context.marks ? `Marks on screen:\n${context.marks}` : null,
        context.memory ? `About the learner: ${context.memory}` : null,
        context.doc ? `Document excerpt:\n${context.doc}` : null,
    ].filter((line): line is string => line !== null);
    if (contextLines.length === 0) return request.prompt;
    return `<context>\n${contextLines.join("\n\n")}\n</context>\n\n${request.prompt}`;
}
