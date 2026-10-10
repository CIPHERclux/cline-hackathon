import ChalkCore
import CoreGraphics
import Foundation

/// Model calls through the real tutor-engine, as the app makes them: the slot's models in
/// order, a deadline, and an abort when the coordinator stops listening.
@MainActor
final class EngineModels {
    let client: TutorEngineClient
    let router: ModelRouter
    private(set) var calls: [(role: GuideRole, model: String, milliseconds: Int, ok: Bool)] = []
    var rateLimitWaits = 0

    init(client: TutorEngineClient, router: ModelRouter) {
        self.client = client
        self.router = router
    }

    func stream(_ request: GuideModelRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            let worker = Task { @MainActor [client, router] in
                let models =
                    (try? router.candidateModels(
                        for: request.slot, requiresVision: request.imageJPEG != nil)) ?? []
                let images = request.imageJPEG.map {
                    ["data:image/jpeg;base64,\($0.base64EncodedString())"]
                } ?? []
                var attempts = models.prefix(2).map { $0 }
                if let first = attempts.first { attempts.insert(first, at: 1) }
                var rateLimited = false
                for (attempt, model) in attempts.enumerated() {
                    if attempt == 1, !rateLimited { continue }
                    if rateLimited {
                        // Free-tier quota: wait it out once (the report counts these).
                        self.rateLimitWaits += 1
                        try? await Task.sleep(for: .seconds(6))
                        rateLimited = false
                    }
                    let startedAt = Date()
                    var sessionIdentifier: String?
                    var gotText = false
                    let events = await client.completeTurn(
                        slot: request.slot.rawValue, model: model, system: request.system,
                        prompt: request.prompt, imageDataURLs: images, maxTokens: request.maxTokens)
                    var reply = ""
                    defer {
                        if ProcessInfo.processInfo.environment["GUIDE_SIM_VERBOSE"] != nil {
                            print("      ⟨\(request.role.rawValue)⟩ \(reply.replacingOccurrences(of: "\n", with: " ").prefix(600))")
                        }
                    }
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .session(let identifier, _): sessionIdentifier = identifier
                        case .text(let delta):
                            gotText = true
                            reply += delta
                            continuation.yield(delta)
                        case .error(let error):
                            if error.kind == "rate_limit" { rateLimited = true }
                            FileHandle.standardError.write(Data("  ⚠️ \(request.role.rawValue) \(model): \(error.kind) \(error.message.prefix(120))\n".utf8))
                        default: break
                        }
                    }
                    if Task.isCancelled, let sessionIdentifier {
                        await client.abort(sessionIdentifier: sessionIdentifier)
                    }
                    self.calls.append((request.role, model, Int(Date().timeIntervalSince(startedAt) * 1000), gotText))
                    if gotText || Task.isCancelled { break }
                }
                continuation.finish()
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(request.timeoutSeconds))
                worker.cancel()
            }
            continuation.onTermination = { _ in
                worker.cancel()
                deadline.cancel()
            }
        }
    }
}

struct RunReport {
    var scenario: String
    var reachedGoal = false
    var finished = false
    var endedEarly = false
    var timedOut = false
    var presentations = 0
    var stepsDone = 0
    var wrongPointers = 0
    var missingControls = 0
    var stalls = 0
    var repeats = 0
    var questions: [String] = []
    var speech: [String] = []
    var stepLatencies: [Int] = []
    var firstStepMilliseconds: Int?
    var modelCalls: [GuideRole: (count: Int, milliseconds: [Int], failures: Int)] = [:]
    var candidateVerdicts: [String] = []
    var log: [String] = []
    var seconds = 0.0
}

/// Plays one scenario: the coordinator guides, the simulated user follows the circle (and
/// deviates where the scenario says), and everything is recorded.
@MainActor
final class SimHarness: GuideEnvironment, GuideDelegate {
    let scenario: Scenario
    let world: SimWorld
    let models: EngineModels
    var coordinator: GuideCoordinator!
    var report: RunReport
    private let startedAt = Date()
    private var presentationCounter = 0
    private var currentPresentation: (number: Int, step: WalkthroughStep, frame: CGRect?)?
    private var lastPresentedInstruction: String?
    private var usedDeviations = Set<Int>()
    private var lastActedAt: Date?
    private var saidLostFor = -1
    private var done = false

    init(scenario: Scenario, models: EngineModels) {
        self.scenario = scenario
        self.world = SimWorld(scenario: scenario)
        self.models = models
        report = RunReport(scenario: scenario.name)
    }

    func run() async -> RunReport {
        coordinator = GuideCoordinator(environment: self)
        coordinator.delegate = self
        world.onChange = { [weak self] in
            self?.coordinator.handle(.screenMayHaveChanged)
        }
        record("goal: \(scenario.goal)")
        coordinator.start(goal: scenario.goal)
        let limit = scenario.maxSeconds ?? 240
        while !done {
            try? await Task.sleep(for: .milliseconds(250))
            if world.reachedGoal { report.reachedGoal = true }
            if Date().timeIntervalSince(startedAt) > limit {
                report.timedOut = true
                record("⏰ timed out")
                coordinator.stop()
                break
            }
            watchForStall()
        }
        report.reachedGoal = report.reachedGoal || world.reachedGoal
        report.seconds = Date().timeIntervalSince(startedAt)
        return report
    }

    private var elapsed: String { String(format: "%5.1fs", Date().timeIntervalSince(startedAt)) }

    private func record(_ line: String) {
        report.log.append("[\(elapsed)] \(line)")
        print("  [\(elapsed)] \(line)")
    }

    // MARK: GuideEnvironment

    func observe(_ depth: GuideObservationDepth, settle: Bool) async -> GuideObservation {
        if settle {
            // The app waits for the screen to stop changing; here, for a loading page to finish.
            var waited = 0
            while world.isLoading, waited < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return GuideObservation(
            appName: world.appName, bundleIdentifier: world.bundleIdentifier,
            snapshot: world.snapshot(),
            visibleTexts: depth == .full ? world.visibleTexts() : world.visibleTexts(),
            imageJPEG: depth == .full ? ScreenRenderer.jpeg(world: world) : nil,
            screenFrame: SimWorld.screen, dockItems: (scenario.dock ?? []).map(\.name))
    }

    func streamModel(_ request: GuideModelRequest) -> AsyncStream<String> {
        models.stream(request)
    }

    func openAppNames() -> [String] { scenario.openApps ?? [] }

    // MARK: GuideDelegate

    func guideStatus(_ text: String?) {}

    func guidePresent(_ presentation: GuidePresentation) async -> GuidePresentResult {
        let step = presentation.step
        guard let frame = ground(step, presentation: presentation) else {
            if step.needsVisibleControl || (step.kind == .type && step.target != nil) {
                report.missingControls += 1
                record("❓ can't find \"\(step.target?.name ?? step.label ?? "?")\" for: \(step.instruction)")
                return .missing
            }
            presentStep(presentation, frame: nil)
            return .shown(target: nil, source: "none")
        }
        presentStep(presentation, frame: frame.rect)
        return .shown(target: frame.rect, source: frame.source)
    }

    private func presentStep(_ presentation: GuidePresentation, frame: CGRect?) {
        presentationCounter += 1
        report.presentations += 1
        if presentation.speaks {
            report.speech.append(presentation.spokenText)
            if presentation.spokenText == lastPresentedInstruction, !presentation.isRepeat {
                report.repeats += 1
            }
            lastPresentedInstruction = presentation.spokenText
        }
        let total = presentation.estimatedTotal.map { " of ~\($0)" } ?? ""
        record("🟠 step \(presentation.number)\(total) [\(presentation.step.kind.rawValue)] \"\(presentation.spokenText)\" → \(frame.map { "circle @\(Int($0.midX)),\(Int($0.midY))" } ?? "no circle")")
        currentPresentation = (presentation.number, presentation.step, frame)
        lastActedAt = nil
        let counter = presentationCounter
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.presentationCounter == counter, !self.done else { return }
            await self.act(presentation.step, frame: frame, number: presentation.number)
        }
    }

    private func ground(_ step: WalkthroughStep, presentation: GuidePresentation)
        -> (rect: CGRect, source: String)?
    {
        let observation = presentation.observation
        if let target = step.target {
            if let snapshot = observation.snapshot, snapshot.isUsable,
                let node = AccessibilityMatcher.bestMatch(for: target, in: snapshot, visibleArea: nil)
            {
                return (node.frame, "accessibility")
            }
            let dock = AccessibilitySnapshot(
                appName: "Dock", bundleIdentifier: "com.apple.dock", focusedWindowTitle: nil,
                documentURL: nil,
                nodes: (scenario.dock ?? []).map {
                    AccessibilityNode(role: "AXDockItem", title: $0.title, frame: $0.rect)
                } + Array(repeating: AccessibilityNode(role: "AXGroup", frame: .zero), count: 5))
            if let node = AccessibilityMatcher.bestMatch(for: target, in: dock, visibleArea: nil) {
                return (node.frame, "accessibility")
            }
        }
        if presentation.pointIsFresh, let point = step.targetPointNorm1000 {
            let global = CGPoint(
                x: point.x / 1000 * SimWorld.screen.width, y: point.y / 1000 * SimWorld.screen.height)
            if let node = world.node(at: global) { return (node.rect, "planned point") }
        }
        if let name = step.target?.name ?? step.label,
            let text = observation.visibleTexts.min(by: {
                (FuzzyTextMatch.rank(candidate: $0.text, wanted: name) ?? 9)
                    < (FuzzyTextMatch.rank(candidate: $1.text, wanted: name) ?? 9)
            }), (FuzzyTextMatch.rank(candidate: text.text, wanted: name) ?? 9) <= 2
        {
            return (text.frame, "text")
        }
        return nil
    }

    func guideClearStep() {}

    func guideSpeak(_ text: String) {
        report.speech.append(text)
        record("🗣️ \(text)")
    }

    func guideNudge() { record("👉 nudge") }

    func guideFiller(_ text: String) {
        report.speech.append(text)
        record("💭 \(text)")
    }

    func guideAsk(question: String, options: [String]) {
        report.questions.append(question)
        record("🃏 card: \(question) \(options)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !self.done else { return }
            let lowered = question.lowercased()
            if let answer = self.scenario.answers?.first(where: { lowered.contains($0.key.lowercased()) })?.value {
                self.record("🙋 says: \(answer)")
                _ = self.coordinator.answer(answer)
            } else {
                self.record("🙋 picks: \(options[0])")
                self.coordinator.choose(options[0])
            }
        }
    }

    func guideHideQuestion() {}

    func guidePaused(_ isPaused: Bool, appName: String?) {
        record(isPaused ? "⏸️ paused" : "▶️ resumed")
    }

    func guideFinished(steps: [WalkthroughStep]) {
        report.finished = true
        report.stepsDone = steps.count
        record("✅ finished after \(steps.count) steps")
        done = true
    }

    func guideEnded() {
        if !report.finished { report.endedEarly = true }
        record("⏹️ ended")
        done = true
    }

    func guideTrace(_ event: GuideTraceEvent) {
        switch event {
        case .modelCall(let role, let milliseconds, let succeeded):
            var entry = report.modelCalls[role] ?? (0, [], 0)
            entry.count += 1
            entry.milliseconds.append(milliseconds)
            if !succeeded { entry.failures += 1 }
            report.modelCalls[role] = entry
            record("   · \(role.rawValue) \(milliseconds) ms\(succeeded ? "" : " ✗")")
        case .presented(let number, let source, let sinceAction):
            if let sinceAction {
                report.stepLatencies.append(sinceAction)
            } else if report.firstStepMilliseconds == nil {
                report.firstStepMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            }
            record("   · shown #\(number) via \(source)\(sinceAction.map { ", \($0) ms after the user acted" } ?? "")")
        case .stepDone(let number, let how):
            record("   · step \(number) done (\(how.prefix(80)))")
        case .candidate(let verdict):
            report.candidateVerdicts.append(verdict)
            record("   · prediction \(verdict)")
        case .asked: break
        case .recovery(let reason):
            record("   · recovery: \(reason.prefix(140))")
        case .note(let text):
            record("   · \(text)")
        case .unusableReply(let role, let excerpt):
            record("   · unusable \(role.rawValue) reply: \(excerpt.prefix(160))")
        }
    }

    // MARK: The simulated user

    private func act(_ step: WalkthroughStep, frame: CGRect?, number: Int) async {
        lastActedAt = Date()
        if let deviation = scenario.deviations?.first(where: { $0.step == number }),
            usedDeviations.insert(number).inserted
        {
            record("🔀 deviation: \(deviation.comment ?? "")")
            var follow = false
            for action in deviation.actions {
                if action.followChalk == true { follow = true; continue }
                await perform(action)
            }
            if !follow { return }
        }
        switch step.kind {
        case .click, .menu, .drag:
            clickChalkTarget(step, frame: frame)
        case .type:
            guard let field = fieldFor(step, frame: frame) else {
                report.wrongPointers += 1
                record("😕 no field to type in")
                return
            }
            world.click(field)
            coordinator.handle(.click(onTarget: true))
            try? await Task.sleep(for: .milliseconds(400))
            let text = valueToType(step, field: field.name)
            record("⌨️ types \"\(text)\" into \(field.name)")
            world.type(text)
            coordinator.handle(.typed)
            try? await Task.sleep(for: .milliseconds(500))
            switch scenario.commit ?? "tab" {
            case "return":
                world.pressReturn()
                coordinator.handle(.returnKey)
            case "click_next":
                let fields = world.currentNodes.filter { $0.field == true && $0.name != field.name }
                if let next = fields.first(where: { $0.rect.minY > field.rect.minY }) {
                    world.click(next)
                    coordinator.handle(.click(onTarget: false))
                }
            case "idle":
                break
            default:
                world.pressTab()
                coordinator.handle(.tabKey)
            }
        case .shortcut:
            guard let combo = step.shortcut, let shortcut = KeyboardShortcut(parsing: combo) else { return }
            record("⌨️ presses \(combo)")
            switch shortcut.key {
            case "return", "enter":
                world.pressReturn()
                coordinator.handle(.returnKey)
            case "tab":
                world.pressTab()
                coordinator.handle(.tabKey)
            default:
                if !world.pressKeys(combo) { record("   (nothing happens)") }
                coordinator.handle(.shortcut(key: shortcut.key, modifiers: shortcut.modifiers))
            }
        case .observe:
            break
        }
    }

    private func clickChalkTarget(_ step: WalkthroughStep, frame: CGRect?) {
        if let frame, let node = world.node(at: CGPoint(x: frame.midX, y: frame.midY)) {
            record("🖱️ clicks \(node.name)")
            world.click(node)
            coordinator.handle(.click(onTarget: true))
            return
        }
        report.wrongPointers += 1
        // A sensible user looks for what the instruction names.
        if let name = step.target?.name, let node = world.node(named: name),
            node.click != nil || node.field == true
        {
            record("😕 circle not on a control; clicks \(node.name) by name")
            world.click(node)
            coordinator.handle(.click(onTarget: false))
        } else {
            record("😕 circle not on a control and nothing called \(step.target?.name ?? "?")")
        }
    }

    private func fieldFor(_ step: WalkthroughStep, frame: CGRect?) -> ScenarioNode? {
        if let frame, let node = world.node(at: CGPoint(x: frame.midX, y: frame.midY)), node.field == true {
            return node
        }
        if let name = step.target?.name, let node = world.node(named: name), node.field == true {
            return node
        }
        return world.currentNodes.first { $0.field == true && $0.name == world.focusedField }
    }

    private func valueToType(_ step: WalkthroughStep, field: String) -> String {
        if case .valueContains(_, let text)? = step.done { return text }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”")]
        for (open, close) in quotes {
            if let start = step.instruction.firstIndex(of: open),
                let end = step.instruction[step.instruction.index(after: start)...].firstIndex(of: close)
            {
                let quoted = String(step.instruction[step.instruction.index(after: start)..<end])
                if !quoted.isEmpty { return quoted }
            }
        }
        return scenario.values?[field] ?? scenario.values?.first { field.localizedCaseInsensitiveContains($0.key) }?.value ?? "hello"
    }

    private func perform(_ action: SimAction) async {
        if let seconds = action.wait { try? await Task.sleep(for: .seconds(seconds)) }
        if let name = action.click, let node = world.node(named: name) {
            record("🖱️ (own way) clicks \(node.name)")
            world.click(node)
            let onTarget = currentPresentation?.frame.map { $0.intersects(node.rect) } ?? false
            coordinator.handle(.click(onTarget: onTarget))
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let text = action.type {
            if let into = action.into, let node = world.node(named: into) {
                world.click(node)
                coordinator.handle(.click(onTarget: false))
            }
            record("⌨️ (own way) types \"\(text)\"")
            world.type(text)
            coordinator.handle(.typed)
            try? await Task.sleep(for: .milliseconds(400))
        }
        if let key = action.key {
            record("⌨️ (own way) presses \(key)")
            switch key {
            case "return":
                world.pressReturn()
                coordinator.handle(.returnKey)
            case "tab":
                world.pressTab()
                coordinator.handle(.tabKey)
            default:
                _ = world.pressKeys(key)
                if let shortcut = KeyboardShortcut(parsing: key) {
                    coordinator.handle(.shortcut(key: shortcut.key, modifiers: shortcut.modifiers))
                }
            }
        }
        if let app = action.switchApp {
            record("🪟 switches to \(app)")
            world.awayApp = app
            world.onChange?()
            coordinator.handle(.appSwitched)
            try? await Task.sleep(for: .seconds(action.backAfter ?? 3))
            record("🪟 back")
            world.awayApp = nil
            world.onChange?()
            coordinator.handle(.appSwitched)
        }
        if let words = action.say {
            record("🙋 says: \(words)")
            if let command = WalkthroughCommand.parse(words) {
                coordinator.handle(command: command)
            } else if !coordinator.answer(words) {
                record("   (a question; not simulated)")
            }
        }
    }

    /// The user acted and nothing moved on for a long time: they'd say they're lost.
    private func watchForStall() {
        guard let lastActedAt, currentPresentation != nil, !coordinator.isAsking else { return }
        let waited = Date().timeIntervalSince(lastActedAt)
        if waited > 30, saidLostFor != presentationCounter {
            saidLostFor = presentationCounter
            report.stalls += 1
            record("🥴 stall: nothing happened for 30 s; says \"I'm lost\"")
            coordinator.handle(command: .replanHere)
        }
    }
}
