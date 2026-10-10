import Foundation

/// One event from tutor-engine, decoded from its NDJSON stdout (§7.3 "IPC protocol", proto 1).
public enum EngineEvent: Equatable, Sendable {
    case session(sessionIdentifier: String, model: String)
    case text(String)
    case toolCall(callIdentifier: String, name: String, input: JSONValue)
    case usage(inputTokens: Int, outputTokens: Int, costInDollars: Double)
    case done(status: String)
    case error(EngineError)
    case pong

    /// `done` and `error` end a request's stream (every request gets exactly one, D38).
    public var isTerminal: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }
}

public struct EngineError: Error, Equatable, Sendable {
    /// auth | rate_limit | network | model | internal (§7.3)
    public var kind: String
    public var isRetryable: Bool
    public var message: String

    public init(kind: String, isRetryable: Bool, message: String) {
        self.kind = kind
        self.isRetryable = isRetryable
        self.message = message
    }
}

/// A decoded stdout line: which request it answers, and the event.
struct EngineEventLine: Sendable {
    var requestIdentifier: String?
    var event: EngineEvent

    init?(line: String) {
        guard let json = JSONValue.parse(line), let eventName = json["ev"]?.stringValue else {
            return nil
        }
        requestIdentifier = json["re"]?.stringValue
        switch eventName {
        case "session":
            guard let sessionIdentifier = json["sessionId"]?.stringValue else { return nil }
            event = .session(
                sessionIdentifier: sessionIdentifier, model: json["model"]?.stringValue ?? "")
        case "text":
            event = .text(json["delta"]?.stringValue ?? "")
        case "tool_call":
            guard let callIdentifier = json["callId"]?.stringValue,
                let name = json["name"]?.stringValue
            else { return nil }
            event = .toolCall(
                callIdentifier: callIdentifier, name: name, input: json["input"] ?? .null)
        case "usage":
            event = .usage(
                inputTokens: json["inputTokens"]?.integerValue ?? 0,
                outputTokens: json["outputTokens"]?.integerValue ?? 0,
                costInDollars: json["costUSD"]?.numberValue ?? 0)
        case "done":
            event = .done(status: json["status"]?.stringValue ?? "completed")
        case "error":
            event = .error(
                EngineError(
                    kind: json["kind"]?.stringValue ?? "internal",
                    isRetryable: json["retryable"] == .bool(true),
                    message: json["message"]?.stringValue ?? ""))
        case "pong":
            event = .pong
        default:
            return nil
        }
    }
}

/// A question for the engine. Images are data URLs (JPEG for the model, §6.2 a / D43).
public struct EngineTurnRequest: Sendable, Equatable {
    public var slot: String
    public var model: String?
    public var prompt: String
    public var imageDataURLs: [String]
    public var context: [String: String]

    public init(
        slot: String, model: String? = nil, prompt: String, imageDataURLs: [String] = [],
        context: [String: String] = [:]
    ) {
        self.slot = slot
        self.model = model
        self.prompt = prompt
        self.imageDataURLs = imageDataURLs
        self.context = context
    }
}

public enum EngineDelivery: String, Sendable {
    case steer, queue
}
