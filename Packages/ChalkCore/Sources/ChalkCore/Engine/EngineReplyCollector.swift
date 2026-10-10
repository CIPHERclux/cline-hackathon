import Foundation

public struct CollectedEngineReply: Sendable {
    public let text: String
    public let sessionIdentifier: String?
}

/// A real deadline: completion resumes immediately, without awaiting an uncooperative child.
/// Cancellation/timeout also aborts the engine request, not merely its Swift iterator (D84).
public actor EngineReplyCollector {
    private var continuation: CheckedContinuation<CollectedEngineReply?, Never>?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var sessionIdentifier: String?
    private var text = ""
    private let client: TutorEngineClient?
    private let maximumBytes: Int

    private init(client: TutorEngineClient?, initialSessionIdentifier: String?, maximumBytes: Int) {
        self.client = client
        self.sessionIdentifier = initialSessionIdentifier
        self.maximumBytes = maximumBytes
    }

    public static func collect(
        from stream: AsyncStream<EngineEvent>, client: TutorEngineClient? = nil,
        initialSessionIdentifier: String? = nil, timeoutSeconds: Double,
        maximumBytes: Int = 24_000
    ) async -> CollectedEngineReply? {
        let collector = EngineReplyCollector(
            client: client, initialSessionIdentifier: initialSessionIdentifier,
            maximumBytes: maximumBytes)
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await collector.start(stream, timeoutSeconds: timeoutSeconds)
        } onCancel: {
            Task { await collector.finish(success: false, abort: true) }
        }
    }

    private func start(_ stream: AsyncStream<EngineEvent>, timeoutSeconds: Double) async
        -> CollectedEngineReply?
    {
        guard !finished else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            reader = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event)
                }
                await self?.finish(success: false, abort: false)
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.001, timeoutSeconds))) } catch {
                    return
                }
                await self?.finish(success: false, abort: true)
            }
        }
    }

    private func receive(_ event: EngineEvent) {
        guard !finished else { return }
        switch event {
        case .session(let identifier, _): sessionIdentifier = identifier
        case .text(let delta):
            guard text.utf8.count + delta.utf8.count <= maximumBytes else {
                finish(success: false, abort: true)
                return
            }
            text += delta
        case .done(let status): finish(success: status == "completed", abort: false)
        case .error: finish(success: false, abort: false)
        case .toolCall(let identifier, _, _):
            if let client {
                Task {
                    await client.sendToolResult(
                        callIdentifier: identifier,
                        result: .object([
                            "ok": .bool(false),
                            "error": .string("Tools unavailable in bounded reply"),
                        ]))
                }
            }
        default: break
        }
    }

    private func finish(success: Bool, abort: Bool) {
        guard !finished else { return }
        finished = true
        reader?.cancel()
        deadline?.cancel()
        reader = nil
        deadline = nil
        let result =
            success ? CollectedEngineReply(text: text, sessionIdentifier: sessionIdentifier) : nil
        continuation?.resume(returning: result)
        continuation = nil
        if abort, let client, let sessionIdentifier {
            Task { await client.abort(sessionIdentifier: sessionIdentifier) }
        }
    }
}
