import Foundation
import Testing

@testable import ChalkCore

/// The Swift client against the real compiled engine and the stub provider (§11.1 "Sidecar";
/// S04 acceptance). Needs `Sidecar/dist/tutor-engine` (bun run build:bin) and bun; skipped
/// otherwise so a plain `swift test` still works on a fresh clone.
enum EngineTestEnvironment {
    static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let engineURL = repositoryRoot.appendingPathComponent("Sidecar/dist/tutor-engine")
    static let bunURL = ["/opt/homebrew/bin/bun", "/usr/local/bin/bun"].map(
        URL.init(fileURLWithPath:)
    )
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    static let isAvailable =
        FileManager.default.isExecutableFile(atPath: engineURL.path) && bunURL != nil
}

/// Runs `Sidecar/test/stub-server.ts` with scripted replies and hands back its base URL.
final class StubServer {
    let process = Process()
    let input = Pipe()
    let baseURL: String

    init(replies: String) throws {
        let output = Pipe()
        process.executableURL = EngineTestEnvironment.bunURL
        process.arguments = [
            EngineTestEnvironment.repositoryRoot.appendingPathComponent(
                "Sidecar/test/stub-server.ts"
            ).path
        ]
        process.environment = ["STUB_REPLIES": replies, "PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var firstLine = Data()
        while !firstLine.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            firstLine.append(chunk)
        }
        baseURL =
            JSONValue.parse(String(decoding: firstLine, as: UTF8.self))?["baseUrl"]?.stringValue
            ?? ""
    }

    deinit {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }
}

func makeEngineClient(stub: StubServer) -> TutorEngineClient {
    let clineDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "chalk-swift-test-\(UUID().uuidString)")
    return TutorEngineClient(
        configuration: .init(
            executableURL: EngineTestEnvironment.engineURL,
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": clineDirectory.path,
                "CLINE_DIR": clineDirectory.path,
                "CHALK_MODEL_PROFILE": "stub", "CHALK_STUB_BASE_URL": stub.baseURL,
            ]))
}

func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
    var events: [EngineEvent] = []
    for await event in stream { events.append(event) }
    return events
}

func spokenTexts(_ events: [EngineEvent]) -> [String] {
    var parser = StreamingScriptParser()
    var scriptEvents: [ScriptEvent] = []
    for case .text(let delta) in events { scriptEvents += parser.feed(delta) }
    scriptEvents += parser.finish()
    return scriptEvents.compactMap { event in
        if case .action(.speak(let speak)) = event { return speak.text }
        return nil
    }
}

@Suite(
    "TutorEngineClient against the compiled engine",
    .enabled(if: EngineTestEnvironment.isAvailable), .serialized)
struct TutorEngineClientTests {
    @Test("bounded collector retains a compiled-engine Guide across three sends")
    func collectedSessionContinuity() async throws {
        let stub = try StubServer(
            replies:
                #"[{"kind":"stream","deltas":["first"]},{"kind":"stream","deltas":["second"]},{"kind":"stream","deltas":["third"]}]"#
        )
        let client = makeEngineClient(stub: stub)
        try await client.launch()
        let first = await EngineReplyCollector.collect(
            from: await client.startTurn(EngineTurnRequest(slot: "teaching", prompt: "first")),
            client: client, timeoutSeconds: 3)
        guard let identifier = first?.sessionIdentifier else {
            await client.shutdown()
            Issue.record("missing session")
            return
        }
        let second = await EngineReplyCollector.collect(
            from: await client.sendTurn(sessionIdentifier: identifier, prompt: "second"),
            client: client, initialSessionIdentifier: identifier, timeoutSeconds: 3)
        let third = await EngineReplyCollector.collect(
            from: await client.sendTurn(sessionIdentifier: identifier, prompt: "third"),
            client: client, initialSessionIdentifier: identifier, timeoutSeconds: 3)
        await client.shutdown()
        #expect(second?.sessionIdentifier == identifier)
        #expect(third?.sessionIdentifier == identifier)
        #expect(second?.text == "second")
        #expect(third?.text == "third")
    }

    @Test("start → session → speak lines in order → done")
    func startDeliversSpeechInOrder() async throws {
        let stub = try StubServer(
            replies:
                #"[{"kind":"stream","deltas":["{\"type\":\"speak\",\"text\":\"One.\"}\n{\"type\":\"spe","ak\",\"text\":\"Two.\"}\n","{\"type\":\"end\"}\n"],"delayBetweenDeltasMs":20}]"#
        )
        let client = makeEngineClient(stub: stub)
        try await client.launch()
        let events = await collect(
            await client.startTurn(EngineTurnRequest(slot: "teaching", prompt: "hi")))
        await client.shutdown()

        guard case .session(_, let model) = events.first else {
            Issue.record("no session event: \(events)")
            return
        }
        #expect(model == "stub-teaching")
        #expect(spokenTexts(events) == ["One.", "Two."])
        #expect(events.last == .done(status: "completed"))
    }

    @Test("abort stops a running turn")
    func abortStopsTurn() async throws {
        let slowDeltas = (0..<60).map { #"{\"type\":\"speak\",\"text\":\"part \#($0)\"}\n"# }.map {
            "\"\($0)\""
        }.joined(separator: ",")
        let stub = try StubServer(
            replies: #"[{"kind":"stream","deltas":[\#(slowDeltas)],"delayBetweenDeltasMs":40}]"#)
        let client = makeEngineClient(stub: stub)
        try await client.launch()
        let stream = await client.startTurn(EngineTurnRequest(slot: "teaching", prompt: "explain"))
        var events: [EngineEvent] = []
        for await event in stream {
            events.append(event)
            if case .session(let sessionIdentifier, _) = event {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await client.abort(sessionIdentifier: sessionIdentifier)
                }
            }
        }
        await client.shutdown()
        #expect(events.last == .done(status: "aborted"))
        #expect(spokenTexts(events).count < 60)
    }

    @Test("kill -9 before any text: the engine restarts and the turn is retried once (P-SIDECAR)")
    func crashRestartsAndRetries() async throws {
        let stub = try StubServer(
            replies:
                #"[{"kind":"stream","deltas":["{\"type\":\"speak\",\"text\":\"lost\"}\n"],"initialDelayMs":3000},{"kind":"stream","deltas":["{\"type\":\"speak\",\"text\":\"Retried answer.\"}\n{\"type\":\"end\"}\n"]}]"#
        )
        let client = makeEngineClient(stub: stub)
        try await client.launch()
        let firstProcessIdentifier = try #require(await client.processIdentifier)
        let stream = await client.startTurn(EngineTurnRequest(slot: "teaching", prompt: "hi"))
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            kill(firstProcessIdentifier, SIGKILL)
        }
        let events = await collect(stream)
        let secondProcessIdentifier = await client.processIdentifier
        await client.shutdown()

        #expect(secondProcessIdentifier != nil && secondProcessIdentifier != firstProcessIdentifier)
        #expect(spokenTexts(events) == ["Retried answer."])
        #expect(events.last == .done(status: "completed"))
    }

    @Test("ping answers while the engine runs")
    func pingAnswers() async throws {
        let stub = try StubServer(replies: "[]")
        let client = makeEngineClient(stub: stub)
        try await client.launch()
        #expect(await client.ping())
        await client.shutdown()
        #expect(await client.ping() == false)
    }
}
