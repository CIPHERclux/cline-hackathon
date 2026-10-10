import ChalkCore
import CoreGraphics
import Foundation
import Testing

/// A scripted screen and scripted helper replies (D86): no engine, no model, no app.
@MainActor
final class FakeGuideWorld: GuideEnvironment, GuideDelegate {
    var snapshot: AccessibilitySnapshot
    var replies: [GuideRole: [String]] = [:]
    var requests: [GuideModelRequest] = []
    var presentations: [GuidePresentation] = []
    var asked: [(String, [String])] = []
    var spoken: [String] = []
    var finishedSteps: [WalkthroughStep]?
    var ended = false

    init(nodes: [AccessibilityNode], window: String = "Inbox") {
        snapshot = Self.snapshot(nodes, window: window)
    }

    static func snapshot(_ nodes: [AccessibilityNode], window: String) -> AccessibilitySnapshot {
        // Padding so the tree counts as readable (five nodes or more).
        let padding = (0..<5).map {
            AccessibilityNode(
                role: "AXGroup", frame: CGRect(x: 0, y: CGFloat($0), width: 1, height: 1))
        }
        return AccessibilitySnapshot(
            appName: "Mail", bundleIdentifier: "com.apple.mail", focusedWindowTitle: window,
            documentURL: nil, nodes: nodes + padding)
    }

    func setScreen(_ nodes: [AccessibilityNode], window: String) {
        snapshot = Self.snapshot(nodes, window: window)
    }

    func observe(_ depth: GuideObservationDepth, settle: Bool) async -> GuideObservation {
        GuideObservation(
            appName: "Mail", bundleIdentifier: "com.apple.mail", snapshot: snapshot,
            imageJPEG: depth == .full ? Data([0xFF]) : nil,
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    func streamModel(_ request: GuideModelRequest) -> AsyncStream<String> {
        requests.append(request)
        var queue = replies[request.role] ?? []
        let reply = queue.isEmpty ? nil : queue.removeFirst()
        replies[request.role] = queue
        return AsyncStream { continuation in
            if let reply { continuation.yield(reply) }
            continuation.finish()
        }
    }

    func openAppNames() -> [String] { ["Mail"] }

    func guideStatus(_ text: String?) {}
    func guidePresent(_ presentation: GuidePresentation) async -> GuidePresentResult {
        presentations.append(presentation)
        guard let target = presentation.step.target else {
            return .shown(target: nil, source: "none")
        }
        guard
            let node = AccessibilityMatcher.bestMatch(
                for: target, in: presentation.observation.snapshot!, visibleArea: nil)
        else { return .missing }
        return .shown(target: node.frame, source: "accessibility")
    }
    func guideClearStep() {}
    func guideSpeak(_ text: String) { spoken.append(text) }
    func guideFiller(_ text: String) {}
    func guideNudge() {}
    func guideAsk(question: String, options: [String]) { asked.append((question, options)) }
    func guideHideQuestion() {}
    func guidePaused(_ isPaused: Bool, appName: String?) {}
    func guideFinished(steps: [WalkthroughStep]) { finishedSteps = steps }
    func guideEnded() { ended = true }
    func guideTrace(_ event: GuideTraceEvent) {}

    func calls(_ role: GuideRole) -> Int { requests.filter { $0.role == role }.count }
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func button(_ name: String, x: CGFloat = 100) -> AccessibilityNode {
    AccessibilityNode(
        role: "AXButton", title: name, frame: CGRect(x: x, y: 50, width: 80, height: 30))
}

private func field(_ name: String, value: String? = nil, focused: Bool = false, y: CGFloat = 200)
    -> AccessibilityNode
{
    AccessibilityNode(
        role: "AXTextField", title: name, value: value,
        frame: CGRect(x: 300, y: y, width: 400, height: 24), isFocused: focused)
}

private var fastSettings: GuideCoordinator.Settings {
    var settings = GuideCoordinator.Settings()
    settings.pollSeconds = 0.05
    settings.typingIdleSeconds = 0.3
    settings.nudgeSeconds = 100
    settings.stuckCheckSeconds = 200
    settings.minimumSecondsBetweenChecks = 0
    settings.pauseGraceSeconds = 0
    return settings
}

@MainActor
@Suite("Guide coordinator (D86)")
struct GuideCoordinatorTests {
    @Test("planner replies parse from one line, fences, nesting and pretty-printing")
    func plannerParsing() {
        let line =
            #"{"do":"step","kind":"click","instruction":"Click New Message.","target":{"role":"button","name":"New Message","px":[340,70]},"done":{"window":"New Message"},"risk":"none","left":3}"#
        guard case .step(let step, _, _, let left)? = GuideAgents.plannerReply(in: line) else {
            Issue.record("no step")
            return
        }
        #expect(step.target?.name == "New Message")
        #expect(left == 3)
        let fenced =
            "```json\n{\n  \"do\": \"ask\",\n  \"question\": \"Which date?\",\n  \"options\": [\"Fri 16\", \"Sat 17\"]\n}\n```"
        #expect(
            GuideAgents.plannerReply(in: fenced)
                == .ask(question: "Which date?", options: ["Fri 16", "Sat 17"]))
        let nested =
            #"Sure. {"status":"step","step":{"kind":"type","instruction":"Type \"Paris\".","target":{"role":"field","name":"Where to?"}}}"#
        guard case .step(let typed, _, _, _)? = GuideAgents.plannerReply(in: nested) else {
            Issue.record("no nested step")
            return
        }
        #expect(typed.done == .valueNotEmpty("Where to?"))
        #expect(
            GuideAgents.plannerReply(in: #"{"do":"step","kind":"click","instruction":"Click it."}"#)
                == nil)
    }

    @Test(
        "a done check that only names the clicked control is dropped; typed text checks the field")
    func predicateSanitising() {
        let selfNamed = GuideAgents.plannerReply(
            in:
                #"{"do":"step","kind":"click","instruction":"Click Dark.","target":{"role":"radio","name":"Dark"},"done":{"exists":"Dark"}}"#
        )
        if case .step(let step, _, _, _)? = selfNamed {
            #expect(step.done == nil)
        } else {
            Issue.record("no step")
        }
        let typed = GuideAgents.plannerReply(
            in:
                #"{"do":"step","kind":"type","instruction":"Type \"sam@example.com\" in To.","target":{"role":"field","name":"To"},"done":{"text":"sam@example.com"}}"#
        )
        if case .step(let step, _, _, _)? = typed {
            #expect(step.done == .valueContains(name: "To", text: "sam@example.com"))
        } else {
            Issue.record("no step")
        }
    }

    @Test("predicates match whole words: To is not October or Today")
    func wholeWordMatching() {
        let snapshot = FakeGuideWorld.snapshot(
            [
                AccessibilityNode(
                    role: "AXRow", title: "Newsletter — October picks",
                    frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
                AccessibilityNode(
                    role: "AXButton", title: "Today",
                    frame: CGRect(x: 0, y: 20, width: 10, height: 10)),
            ],
            window: "Inbox")
        #expect(
            DonePredicate.exists("To").evaluate(
                snapshot: snapshot, frontmostAppName: "Mail", visibleTexts: nil) == false)
        #expect(
            DonePredicate.exists("October picks").evaluate(
                snapshot: snapshot, frontmostAppName: "Mail", visibleTexts: nil) == true)
    }

    @Test("a prediction that fits the new screen is shown with no planner call")
    func scoutPredictionSkipsPlanner() async {
        let world = FakeGuideWorld(nodes: [button("New Message")])
        world.replies[.planner] = [
            #"{"do":"step","kind":"click","instruction":"Click New Message.","target":{"role":"button","name":"New Message"},"done":{"window":"New Message"},"left":2}"#
        ]
        world.replies[.scout] = [
            #"{"if":{"window":"New Message"},"step":{"kind":"type","instruction":"Type \"sam@example.com\" in To.","target":{"role":"field","name":"To"},"done":{"value_contains":{"name":"To","text":"sam@example.com"}}}}"#
        ]
        let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
        coordinator.delegate = world
        coordinator.start(goal: "Email Sam")
        #expect(await waitUntil { world.presentations.count == 1 })
        #expect(await waitUntil { world.calls(.scout) == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        world.setScreen([button("New Message"), field("To", focused: true)], window: "New Message")
        coordinator.handle(.click(onTarget: true))
        #expect(await waitUntil { world.presentations.count == 2 })
        #expect(world.presentations[1].step.target?.name == "To")
        #expect(world.calls(.planner) == 1)
    }

    @Test("typing finishes on Tab, on focus moving on, or after a pause; never on half a value")
    func typingCommits() async {
        for finish in ["tab", "focus", "idle"] {
            let world = FakeGuideWorld(nodes: [
                field("Subject", focused: true), field("Body", y: 300),
            ])
            world.replies[.planner] = [
                #"{"do":"step","kind":"type","instruction":"Type a subject.","target":{"role":"field","name":"Subject"},"done":{"value_not_empty":"Subject"}}"#,
                #"{"do":"done","evidence":"subject typed"}"#,
            ]
            world.replies[.checker] = [#"{"reached":true,"evidence":"ok"}"#]
            let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
            coordinator.delegate = world
            coordinator.start(goal: "Write a subject")
            #expect(await waitUntil { world.presentations.count == 1 })
            world.setScreen(
                [field("Subject", value: "Runn", focused: true), field("Body", y: 300)],
                window: "Inbox")
            coordinator.handle(.typed)
            try? await Task.sleep(for: .milliseconds(150))
            #expect(coordinator.completedSteps.isEmpty, "half-typed must not finish (\(finish))")
            world.setScreen(
                [
                    field("Subject", value: "Running late", focused: finish != "focus"),
                    field("Body", focused: finish == "focus", y: 300),
                ], window: "Inbox")
            switch finish {
            case "tab": coordinator.handle(.tabKey)
            case "focus": coordinator.handle(.screenMayHaveChanged)
            default: coordinator.handle(.typed)
            }
            #expect(await waitUntil { coordinator.completedSteps.count == 1 }, "\(finish)")
        }
    }

    @Test("a click on the circle that makes the app react finishes the step without a model")
    func reactedClick() async {
        let world = FakeGuideWorld(nodes: [button("Compose")])
        world.replies[.planner] = [
            #"{"do":"step","kind":"click","instruction":"Click Compose.","target":{"role":"button","name":"Compose"},"done":{"exists":"Compose"}}"#
        ]
        let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
        coordinator.delegate = world
        coordinator.start(goal: "Write an email")
        #expect(await waitUntil { world.presentations.count == 1 })
        world.setScreen([button("Compose"), field("To", focused: true)], window: "New Message")
        coordinator.handle(.click(onTarget: true))
        #expect(await waitUntil { coordinator.completedSteps.count == 1 })
        #expect(world.calls(.checker) == 0)
    }

    @Test("an action with consequences gets a spoken heads-up, never a confirmation card")
    func consequentialHeadsUp() async {
        let world = FakeGuideWorld(nodes: [button("Send")], window: "New Message")
        world.replies[.planner] = [
            #"{"do":"step","kind":"click","instruction":"Click Send.","target":{"role":"button","name":"Send"},"done":{"gone":"New Message"},"risk":"none"}"#
        ]
        let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
        coordinator.delegate = world
        coordinator.start(goal: "Send it")
        #expect(await waitUntil { world.presentations.count == 1 })
        #expect(world.presentations.first?.headsUp != nil)
        #expect(world.asked.isEmpty)
    }

    @Test("a control that isn't there is planned around silently, the fixer after two misses")
    func missingControlRecovery() async {
        let world = FakeGuideWorld(nodes: [button("Compose")])
        let missing =
            #"{"do":"step","kind":"click","instruction":"Click Write.","target":{"role":"button","name":"Write"}}"#
        world.replies[.planner] = [missing]
        world.replies[.fixer] = [
            missing,
            #"{"do":"step","kind":"click","instruction":"Click Compose.","target":{"role":"button","name":"Compose"}}"#,
        ]
        world.replies[.planner]?.append(missing)
        let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
        coordinator.delegate = world
        coordinator.start(goal: "Write an email")
        #expect(await waitUntil { world.presentations.last?.step.target?.name == "Compose" })
        #expect(world.calls(.fixer) >= 1)
        #expect(world.asked.isEmpty)
    }

    @Test("a spoken answer that matches no option becomes the user's own direction")
    func freeTextAnswer() async {
        let world = FakeGuideWorld(nodes: [button("Compose")])
        world.replies[.planner] = [
            #"{"do":"ask","question":"Which account?","options":["Work","Personal"]}"#,
            #"{"do":"step","kind":"click","instruction":"Click Compose.","target":{"role":"button","name":"Compose"}}"#,
        ]
        world.replies[.checker] = [#"{"option":0,"means":"the school one"}"#]
        let coordinator = GuideCoordinator(environment: world, settings: fastSettings)
        coordinator.delegate = world
        coordinator.start(goal: "Write an email")
        #expect(await waitUntil { world.asked.count == 1 })
        #expect(coordinator.answer("use my school account"))
        #expect(await waitUntil { world.presentations.count == 1 })
        #expect(coordinator.ledger?.decisions.first?.contains("school") == true)
        let plannerPrompts = world.requests.filter { $0.role == .planner }.map(\.prompt)
        #expect(plannerPrompts.last?.contains("use my school account") == true)
    }

    @Test("a prediction is strong, medium or rejected against the real screen")
    func assessment() {
        let observation = GuideObservation(
            appName: "Mail", bundleIdentifier: "com.apple.mail",
            snapshot: FakeGuideWorld.snapshot(
                [button("Send"), field("To", focused: true)], window: "New Message"))
        let exact = GuideCandidate(
            step: WalkthroughStep(
                kind: .click, instruction: "Click Send.",
                target: ElementQuery(role: .button, name: "Send"), app: "Mail"),
            precondition: .window("New Message"), source: "scout")
        #expect(GuideCandidateAssessor.assess(exact, on: observation) == .strong)
        var wrongApp = exact
        wrongApp.step.app = "Safari"
        #expect(
            GuideCandidateAssessor.assess(wrongApp, on: observation) == .reject("different app"))
        let absent = GuideCandidate(
            step: WalkthroughStep(
                kind: .click, instruction: "Click Archive.",
                target: ElementQuery(role: .button, name: "Archive")),
            precondition: nil, source: "scout")
        #expect(
            GuideCandidateAssessor.assess(absent, on: observation)
                == .reject("control not on screen"))
        let falsePrecondition = GuideCandidate(
            step: exact.step, precondition: .window("Inbox"), source: "scout")
        #expect(
            GuideCandidateAssessor.assess(falsePrecondition, on: observation)
                == .reject("precondition false"))
    }
}
