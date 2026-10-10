import Foundation
import Testing

@testable import ChalkCore

@Suite("Engine deadlines, predicates and choices (D84, D86)")
struct GuideSupportTests {
    @Test("follow-up without a session event retains the existing session")
    func continuation() async {
        let stream = AsyncStream<EngineEvent> { continuation in
            continuation.yield(.text("reply"))
            continuation.yield(.done(status: "completed"))
            continuation.finish()
        }
        let reply = await EngineReplyCollector.collect(
            from: stream, initialSessionIdentifier: "same-session", timeoutSeconds: 1)
        #expect(reply?.sessionIdentifier == "same-session")
        #expect(reply?.text == "reply")
    }

    @Test("new sessions replace the prior identifier")
    func newSession() async {
        let stream = AsyncStream<EngineEvent> { continuation in
            continuation.yield(.session(sessionIdentifier: "new", model: "stub"))
            continuation.yield(.done(status: "completed"))
        }
        let reply = await EngineReplyCollector.collect(
            from: stream, initialSessionIdentifier: "old", timeoutSeconds: 1)
        #expect(reply?.sessionIdentifier == "new")
    }

    @Test("deadline returns promptly even if the producer never terminates")
    func deadline() async {
        let stream = AsyncStream<EngineEvent> { _ in }
        let started = Date()
        let reply = await EngineReplyCollector.collect(from: stream, timeoutSeconds: 0.03)
        #expect(reply == nil)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test("cancellation returns promptly and oversized output is rejected")
    func cancellation() async {
        let stream = AsyncStream<EngineEvent> { _ in }
        let task = Task { await EngineReplyCollector.collect(from: stream, timeoutSeconds: 30) }
        task.cancel()
        #expect(await task.value == nil)
        let oversized = AsyncStream<EngineEvent> { continuation in
            continuation.yield(.text("too long"))
        }
        #expect(
            await EngineReplyCollector.collect(from: oversized, timeoutSeconds: 1, maximumBytes: 2)
                == nil)
    }

    @Test("compound completion cannot silently discard an unknown predicate")
    func compound() {
        #expect(
            DonePredicate(
                json: JSONValue.parse(#"{"all":[{"window":"Mail"},{"invented":"yes"}]}"#)!) == nil)
    }

    @Test("shared evidence includes focused values but excludes secure fields")
    func observationContext() {
        var snapshot = AccessibilityMatchingTests().snapshot
        snapshot.nodes.append(
            AccessibilityNode(
                role: "AXSecureTextField", label: "Password", value: "do-not-send", frame: .zero,
                isFocused: true))
        let context = WalkthroughPrompts.evidenceSummary(snapshot)
        #expect(context.contains("Window: New Message"))
        #expect(context.contains("focused=true"))
        #expect(!context.contains("do-not-send"))
    }

    @Test("unrelated focused value cannot satisfy a missing named field")
    func fieldIdentity() {
        var snapshot = AccessibilityMatchingTests().snapshot
        snapshot.nodes.removeAll { $0.label == "Subject" }
        snapshot.nodes.append(
            AccessibilityNode(
                role: "AXStaticText", value: "Subject",
                frame: .init(x: 0, y: 0, width: 10, height: 10)))
        for index in snapshot.nodes.indices where snapshot.nodes[index].isFocused {
            snapshot.nodes[index].value = "unrelated"
        }
        #expect(
            DonePredicate.valueNotEmpty("Subject").evaluate(
                snapshot: snapshot, frontmostAppName: "Mail", visibleTexts: nil) == nil)
    }

    @Test("choices match exact names and ordinals but don't guess ambiguous speech")
    func choices() {
        let decision = AdaptiveDecision(question: "Which format?", options: ["Web", "Editing"])
        #expect(decision.answer(matching: "web") == "Web")
        #expect(decision.answer(matching: "option 2") == "Editing")
        #expect(decision.answer(matching: "second") == "Editing")
        #expect(decision.answer(matching: "anything") == nil)
    }
}
