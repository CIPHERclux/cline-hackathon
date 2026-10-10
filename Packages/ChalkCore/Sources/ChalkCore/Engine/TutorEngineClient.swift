import Foundation

/// Runs tutor-engine (the Cline sidecar) as a child process and talks to it over NDJSON on
/// stdin/stdout (§7.3 "Process model & supervision"):
/// - each request gets its own event stream, which ends on that request's `done` or `error`;
/// - health pings run every 10 s **only while a turn is in flight**, never when idle (§6.5,
///   P-IDLECPU);
/// - if the engine dies, it is restarted with exponential backoff (0.5 s → 8 s, at most 5 per
///   minute) and each in-flight `start` that had not produced text yet is retried once (P-SIDECAR).
///   A turn that already produced text fails instead, because replaying it would repeat speech;
/// - shutdown: close stdin (the engine disposes and exits), then SIGTERM, then SIGKILL after 2 s.
public actor TutorEngineClient {
    public struct Configuration: Sendable {
        public var executableURL: URL
        public var environment: [String: String]
        public var pingIntervalSeconds: Double
        public var pingTimeoutSeconds: Double
        public var maximumRestartsPerMinute: Int

        public init(
            executableURL: URL, environment: [String: String], pingIntervalSeconds: Double = 10,
            pingTimeoutSeconds: Double = 3, maximumRestartsPerMinute: Int = 5
        ) {
            self.executableURL = executableURL
            self.environment = environment
            self.pingIntervalSeconds = pingIntervalSeconds
            self.pingTimeoutSeconds = pingTimeoutSeconds
            self.maximumRestartsPerMinute = maximumRestartsPerMinute
        }
    }

    public enum Notice: Sendable, Equatable {
        case restarted(retriedTurnCount: Int)
        case restartLimitReached
    }

    private struct OpenTurn {
        var continuation: AsyncStream<EngineEvent>.Continuation
        var requestLine: Data
        var canBeRetried: Bool
        var hasDeliveredText = false
        var hasBeenRetried = false
    }

    private let configuration: Configuration
    private var process: Process?
    private var standardInput: FileHandle?
    private var launchGeneration = 0
    private var isShuttingDown = false
    private var requestCounter = 0
    private var unprocessedOutput = Data()
    private var openTurns: [String: OpenTurn] = [:]
    private var singleReplyWaiters: [String: CheckedContinuation<EngineEvent?, Never>] = [:]
    private var recentRestartDates: [Date] = []
    private var restartBackoffSeconds = 0.5
    private var healthCheckTask: Task<Void, Never>?
    private let noticeContinuation: AsyncStream<Notice>.Continuation

    /// Restarts and give-ups, for logging.
    public nonisolated let notices: AsyncStream<Notice>

    public init(configuration: Configuration) {
        self.configuration = configuration
        (notices, noticeContinuation) = AsyncStream<Notice>.makeStream()
        // Writing to a pipe whose reader died raises SIGPIPE, which would kill the app. With it
        // ignored, the write throws instead and the termination handler restarts the engine.
        signal(SIGPIPE, SIG_IGN)
    }

    public var processIdentifier: Int32? { process?.processIdentifier }
    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    public func launch() throws {
        guard process == nil else { return }
        isShuttingDown = false
        launchGeneration += 1
        let generation = launchGeneration

        let process = Process()
        process.executableURL = configuration.executableURL
        process.environment = configuration.environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        // Chunks are funnelled through one stream so they are processed strictly in order.
        let (outputChunks, outputContinuation) = AsyncStream<Data>.makeStream()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outputContinuation.finish()
            } else {
                outputContinuation.yield(chunk)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination(generation: generation) }
        }
        try process.run()
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        unprocessedOutput = Data()

        Task { [weak self] in
            for await chunk in outputChunks {
                await self?.receive(chunk, generation: generation)
            }
        }
    }

    public func shutdown() async {
        isShuttingDown = true
        healthCheckTask?.cancel()
        healthCheckTask = nil
        failAllOpenRequests(message: "tutor-engine is shutting down")
        guard let process else { return }
        try? standardInput?.close()
        standardInput = nil
        if await waitForExit(of: process, seconds: 2) == false {
            process.terminate()
            if await waitForExit(of: process, seconds: 2) == false {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
    }

    // MARK: - Requests

    /// Starts a new session and asks the first question. The stream ends with `done` or `error`.
    public func startTurn(_ request: EngineTurnRequest) -> AsyncStream<EngineEvent> {
        var payload: [String: Any] = [
            "op": "start", "slot": request.slot, "prompt": request.prompt,
        ]
        if let model = request.model { payload["model"] = model }
        if !request.imageDataURLs.isEmpty { payload["images"] = request.imageDataURLs }
        if !request.context.isEmpty { payload["context"] = request.context }
        return openTurn(payload: payload, canBeRetried: true)
    }

    /// The fast path (D74): one stateless streamed call with its own short system prompt (no
    /// agent loop, no session). Same stream shape as a turn: `session` (abortable), `text`, end.
    public func completeTurn(
        slot: String, model: String?, system: String, prompt: String,
        imageDataURLs: [String] = [], maxTokens: Int? = nil
    ) -> AsyncStream<EngineEvent> {
        var payload: [String: Any] = [
            "op": "complete", "slot": slot, "system": system, "prompt": prompt,
        ]
        if let model { payload["model"] = model }
        if !imageDataURLs.isEmpty { payload["images"] = imageDataURLs }
        if let maxTokens { payload["maxTokens"] = maxTokens }
        return openTurn(payload: payload, canBeRetried: true)
    }

    /// Asks within an existing session: a follow-up when idle, or a barge-in (`steer`) while a
    /// turn is still running (§7.6). Not retried after a crash: the session died with the engine.
    public func sendTurn(
        sessionIdentifier: String, prompt: String, model: String? = nil,
        imageDataURLs: [String] = [],
        delivery: EngineDelivery? = nil
    ) -> AsyncStream<EngineEvent> {
        var payload: [String: Any] = [
            "op": "send", "sessionId": sessionIdentifier, "prompt": prompt,
        ]
        if let model { payload["model"] = model }
        if !imageDataURLs.isEmpty { payload["images"] = imageDataURLs }
        if let delivery { payload["delivery"] = delivery.rawValue }
        return openTurn(payload: payload, canBeRetried: false)
    }

    /// Stops the running turn of a session (barge-in "stop", §7.6).
    public func abort(sessionIdentifier: String) async {
        _ = await singleReply(
            payload: ["op": "abort", "sessionId": sessionIdentifier], timeoutSeconds: 2)
    }

    /// §7.3 Warm-up: one tiny request so TLS and auth are open before the first real question.
    public func prewarm(slot: String) async -> EngineEvent? {
        await singleReply(payload: ["op": "prewarm", "slot": slot], timeoutSeconds: 20)
    }

    public func ping() async -> Bool {
        await singleReply(payload: ["op": "ping"], timeoutSeconds: configuration.pingTimeoutSeconds)
            == .pong
    }

    public func sendToolResult(callIdentifier: String, result: JSONValue) async {
        _ = await singleReply(
            payload: [
                "op": "tool_result", "callId": callIdentifier, "result": result.foundationObject,
            ], timeoutSeconds: 2)
    }

    // MARK: - Private: requests

    private func nextRequestIdentifier() -> String {
        requestCounter += 1
        return "c\(requestCounter)"
    }

    private func encodedLine(_ payload: [String: Any], requestIdentifier: String) -> Data {
        var payloadWithIdentifier = payload
        payloadWithIdentifier["id"] = requestIdentifier
        var line = (try? JSONSerialization.data(withJSONObject: payloadWithIdentifier)) ?? Data()
        line.append(0x0A)
        return line
    }

    private func openTurn(payload: [String: Any], canBeRetried: Bool) -> AsyncStream<EngineEvent> {
        let requestIdentifier = nextRequestIdentifier()
        let line = encodedLine(payload, requestIdentifier: requestIdentifier)
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        openTurns[requestIdentifier] = OpenTurn(
            continuation: continuation, requestLine: line, canBeRetried: canBeRetried)
        startHealthChecksIfNeeded()
        if !write(line) {
            finishTurn(
                requestIdentifier,
                with: .error(
                    EngineError(
                        kind: "internal", isRetryable: true, message: "tutor-engine is not running")
                ))
        }
        return stream
    }

    private func singleReply(payload: [String: Any], timeoutSeconds: Double) async -> EngineEvent? {
        let requestIdentifier = nextRequestIdentifier()
        let line = encodedLine(payload, requestIdentifier: requestIdentifier)
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<EngineEvent?, Never>) in
            singleReplyWaiters[requestIdentifier] = continuation
            guard write(line) else {
                resolveWaiter(requestIdentifier, with: nil)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.resolveWaiter(requestIdentifier, with: nil)
            }
        }
    }

    private func resolveWaiter(_ requestIdentifier: String, with event: EngineEvent?) {
        singleReplyWaiters.removeValue(forKey: requestIdentifier)?.resume(returning: event)
    }

    private func write(_ line: Data) -> Bool {
        guard let standardInput else { return false }
        do {
            try standardInput.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private func finishTurn(_ requestIdentifier: String, with event: EngineEvent) {
        guard let turn = openTurns.removeValue(forKey: requestIdentifier) else { return }
        turn.continuation.yield(event)
        turn.continuation.finish()
        if case .done = event { restartBackoffSeconds = 0.5 }
        if openTurns.isEmpty {
            healthCheckTask?.cancel()
            healthCheckTask = nil
        }
    }

    // MARK: - Private: output

    private func receive(_ chunk: Data, generation: Int) {
        guard generation == launchGeneration else { return }
        unprocessedOutput.append(chunk)
        while let newlineIndex = unprocessedOutput.firstIndex(of: 0x0A) {
            let lineData = unprocessedOutput[unprocessedOutput.startIndex..<newlineIndex]
            unprocessedOutput.removeSubrange(unprocessedOutput.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8),
                let decoded = EngineEventLine(line: line),
                let requestIdentifier = decoded.requestIdentifier
            else { continue }
            route(decoded.event, to: requestIdentifier)
        }
    }

    private func route(_ event: EngineEvent, to requestIdentifier: String) {
        if singleReplyWaiters[requestIdentifier] != nil {
            // A single-reply request resolves on its first answer (pong, done, error or usage).
            resolveWaiter(requestIdentifier, with: event)
            return
        }
        guard var turn = openTurns[requestIdentifier] else { return }
        if event.isTerminal {
            finishTurn(requestIdentifier, with: event)
            return
        }
        if case .text = event {
            turn.hasDeliveredText = true
            openTurns[requestIdentifier] = turn
        }
        turn.continuation.yield(event)
    }

    // MARK: - Private: supervision

    private func startHealthChecksIfNeeded() {
        guard healthCheckTask == nil else { return }
        let interval = configuration.pingIntervalSeconds
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.checkHealthWhileActive()
            }
        }
    }

    private func checkHealthWhileActive() async {
        guard !openTurns.isEmpty, let process else { return }
        if await ping() == false, process.isRunning {
            // Hung: kill it; the termination handler restarts it and retries the turns.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func handleTermination(generation: Int) async {
        guard generation == launchGeneration, !isShuttingDown else { return }
        process = nil
        standardInput = nil
        for requestIdentifier in Array(singleReplyWaiters.keys) {
            resolveWaiter(requestIdentifier, with: nil)
        }

        var turnIdentifiersToRetry: [String] = []
        for (requestIdentifier, turn) in openTurns {
            if turn.canBeRetried && !turn.hasDeliveredText && !turn.hasBeenRetried {
                turnIdentifiersToRetry.append(requestIdentifier)
            } else {
                finishTurn(
                    requestIdentifier,
                    with: .error(
                        EngineError(
                            kind: "internal", isRetryable: true,
                            message: "tutor-engine stopped unexpectedly")))
            }
        }

        let now = Date()
        recentRestartDates = recentRestartDates.filter { now.timeIntervalSince($0) < 60 }
        guard recentRestartDates.count < configuration.maximumRestartsPerMinute else {
            noticeContinuation.yield(.restartLimitReached)
            failAllOpenRequests(message: "tutor-engine keeps crashing; not restarting for now")
            return
        }
        recentRestartDates.append(now)
        let backoffSeconds = restartBackoffSeconds
        restartBackoffSeconds = min(restartBackoffSeconds * 2, 8)
        try? await Task.sleep(for: .seconds(backoffSeconds))
        guard !isShuttingDown, process == nil else { return }

        do {
            try launch()
        } catch {
            failAllOpenRequests(
                message: "tutor-engine could not be restarted: \(error.localizedDescription)")
            return
        }
        for requestIdentifier in turnIdentifiersToRetry {
            guard var turn = openTurns[requestIdentifier] else { continue }
            turn.hasBeenRetried = true
            openTurns[requestIdentifier] = turn
            if !write(turn.requestLine) {
                finishTurn(
                    requestIdentifier,
                    with: .error(
                        EngineError(kind: "internal", isRetryable: true, message: "retry failed")))
            }
        }
        noticeContinuation.yield(.restarted(retriedTurnCount: turnIdentifiersToRetry.count))
    }

    private func failAllOpenRequests(message: String) {
        for requestIdentifier in Array(openTurns.keys) {
            finishTurn(
                requestIdentifier,
                with: .error(EngineError(kind: "internal", isRetryable: true, message: message)))
        }
        for requestIdentifier in Array(singleReplyWaiters.keys) {
            resolveWaiter(requestIdentifier, with: nil)
        }
    }

    private func waitForExit(of process: Process, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }
}

extension JSONValue {
    /// Back to Foundation types, for JSONSerialization.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let dictionary): return dictionary.mapValues(\.foundationObject)
        }
    }
}
