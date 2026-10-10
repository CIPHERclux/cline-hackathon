import CoreGraphics
import Foundation

/// Runs one guided task (§4.2.6, D86). Chalk coordinates bounded helpers that all read the same
/// ledger, never agents calling agents:
/// - planner (Sonnet): the next single action from the current screen; its one-line reply is
///   used the moment it arrives;
/// - scout (Sonnet, background): while the user does a step, predicts the next one, so a
///   matching prediction is shown with no wait;
/// - checker (Haiku): "did that work?", "is the predicted step right?", "is the goal reached?",
///   "which option did they mean?";
/// - fixer (Opus): only when guiding is stuck.
/// The user's own actions are watched locally (accessibility predicates, keys, clicks); a model
/// is asked only when the app can't tell.
@MainActor
public final class GuideCoordinator {
    public struct Settings: Sendable {
        public var nudgeSeconds = 20.0
        public var stuckCheckSeconds = 45.0
        public var pollSeconds = 1.0
        /// Typing that stops this long counts as finished (some users never press Return/Tab).
        public var typingIdleSeconds = 1.5
        /// Silence longer than this while Chalk thinks gets a short spoken filler.
        public var fillerAfterSeconds = 1.2
        /// Another app this soon after a step appears is the step's own effect, not leaving.
        public var pauseGraceSeconds = 1.5
        public var targetGoneSeconds = 1.5
        // Safety nets against a hung call only; replies are never cut short (D86).
        public var plannerTimeoutSeconds = 30.0
        public var scoutTimeoutSeconds = 30.0
        public var checkerTimeoutSeconds = 20.0
        public var fixerTimeoutSeconds = 45.0
        public var minimumSecondsBetweenChecks = 1.5
        public var maximumSteps = 30

        public init() {}
    }

    private enum Phase: Equatable { case idle, thinking, watching, asking, paused, finished }

    private enum AskPurpose: Equatable { case model, retry, confirmFinish }

    private struct ActiveStep {
        var step: WalkthroughStep
        var number: Int
        var presentedAt: Date
        var targetFrame: CGRect?
        var foundByAccessibility: Bool
        /// The predicate was already true when shown: it can't tell this step apart.
        var predicateIsUseless: Bool
        var baselineFieldValue: String?
        var bundleIdentifier: String?
        var appName: String?
        var dialogCount: Int
        var typed = false
        var committed = false
        var actedOnTarget = false
        var pressedShortcut = false
        var lastTypingAt: Date?
        var targetMissingSince: Date?
        /// What the screen looked like when shown, to notice that a click made the app react.
        var baselineFingerprint: String
        var checkRetries = 0
        /// The screen the step was shown on: a scout prediction whose precondition was false
        /// here and is true now means the step happened.
        var presentedObservation: GuideObservation
        var hasGivenAdvice = false
    }

    /// No practical cap: Claude 5.5 reasons before it answers, and a tight cap cut replies in
    /// half (D86). The prompts keep answers short.
    static let replyTokenLimit = 8192

    public weak var delegate: GuideDelegate?
    public let settings: Settings
    private let environment: GuideEnvironment

    public private(set) var ledger: GuideLedger?
    public private(set) var completedSteps: [WalkthroughStep] = []
    private var phase = Phase.idle
    private var active: ActiveStep?
    private var candidates: [GuideCandidate] = []
    private var estimatedRemaining: Int?
    /// Bumped whenever the task moves on; late helper replies for an older context are dropped.
    private var generation = 0
    private var troubles = 0
    private var goalMisses = 0
    private var pendingAsk: (question: String, options: [String], purpose: AskPurpose)?
    private var isSuspended = false
    private var lastUserActionAt: Date?
    private var lastCheckAt = Date.distantPast

    private var thinkTask: Task<Void, Never>?
    private var scoutTask: Task<[GuideCandidate], Never>?
    private var scoutGeneration = -1
    private var scoutFinished = true
    /// The scout expects the step just shown to finish the task: check the goal, skip planning.
    private var scoutExpectsFinish = false
    private var checkTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var isEvaluating = false
    private var evaluateAgain: Bool?
    private var typingIdleTask: Task<Void, Never>?
    private var fillerTask: Task<Void, Never>?
    private var checkToken = 0
    private var lastFiller: String?
    private var leadInIndex = 0

    static let planningFillers = [
        "Working out the next step.", "One moment, I'm looking.", "Thinking about the best way.",
    ]
    static let checkingFillers = ["Let me check that.", "Checking that worked."]
    static let leadIns = [
        "Okay, here's the next step.", "Good. Here's the next one.", "Nice. Next step.",
    ]

    public init(environment: GuideEnvironment, settings: Settings = Settings()) {
        self.environment = environment
        self.settings = settings
    }

    public var isActive: Bool { phase != .idle && phase != .finished }
    public var goal: String? { ledger?.goal }
    public var isAsking: Bool { pendingAsk != nil }
    public var currentStep: WalkthroughStep? { active?.step }
    public var progressText: String {
        let number = completedSteps.count + 1
        guard let estimatedRemaining else { return "Step \(number)" }
        return "Step \(number) of ~\(number + estimatedRemaining)"
    }

    // MARK: - Starting and stopping

    /// `savedSteps` (a saved how-to) are tried in order as predictions; the planner takes over
    /// whenever one doesn't fit the screen.
    public func start(
        goal: String, savedSteps: [WalkthroughStep] = [],
        initialObservation: GuideObservation? = nil
    ) {
        cancelEverything()
        lastUserActionAt = nil
        ledger = GuideLedger(goal: goal)
        completedSteps = []
        candidates = savedSteps.map { GuideCandidate(step: $0, precondition: nil, source: "saved") }
        estimatedRemaining = savedSteps.isEmpty ? nil : savedSteps.count - 1
        troubles = 0
        goalMisses = 0
        phase = .thinking
        generation += 1
        let currentGeneration = generation
        delegate?.guideStatus("Looking at your screen")
        let opener = savedSteps.isEmpty ? "Let me look at your screen." : "Let's do it again."
        lastFiller = opener
        delegate?.guideFiller(opener)
        startFiller(Self.planningFillers)
        thinkTask = Task { [weak self] in
            guard let self else { return }
            var observation = initialObservation
            if observation?.hasScreenshot != true {
                observation = await self.environment.observe(.full, settle: true)
            }
            guard let observation, self.generation == currentGeneration else { return }
            await self.advance(from: observation, note: nil, generation: currentGeneration)
        }
    }

    /// Ends without a recap (a new task, "stop", the app quitting).
    public func stop() {
        guard phase != .idle else { return }
        cancelEverything()
        phase = .idle
        active = nil
        pendingAsk = nil
        delegate?.guideHideQuestion()
        delegate?.guideClearStep()
        delegate?.guideEnded()
    }

    private func cancelEverything() {
        stopFiller()
        generation += 1
        thinkTask?.cancel()
        thinkTask = nil
        dropScout()
        checkTask?.cancel()
        checkTask = nil
        stopWatching()
    }

    // MARK: - Talk key and questions

    /// The user holds the talk key or asks a question: nothing new is shown until `resume`.
    public func suspend() {
        isSuspended = true
        hintTask?.cancel()
        hintTask = nil
    }

    /// `preface`: say the current step again after a question ("Back to it."). `redraw`: the
    /// talk key cleared the circle, so show it again quietly.
    public func resume(preface: String?, redraw: Bool = true) {
        guard isSuspended else { return }
        isSuspended = false
        guard phase == .watching, let active else { return }
        if preface != nil || redraw {
            represent(preface: preface, speaks: preface != nil, isRepeat: false)
        } else {
            startHints(for: active.step)
        }
    }

    // MARK: - Moving the task on

    private func advance(from observation: GuideObservation, note: String?, generation: Int)
        async
    {
        guard generation == self.generation, ledger != nil else { return }
        guard completedSteps.count < settings.maximumSteps else {
            end(saying: "That's a long one. Let's stop here; ask again for the rest.")
            return
        }
        phase = .thinking
        // A prediction from the scout (or a saved how-to) may already fit this screen. A scout
        // still thinking races a fresh plan.
        if candidates.isEmpty, let pendingScout = scoutTask, !scoutFinished {
            await raceScout(
                pendingScout, observation: observation, note: note, generation: generation)
            return
        }
        if candidates.isEmpty, scoutExpectsFinish, note == nil {
            scoutExpectsFinish = false
            dropScout()
            await verifyGoal(
                claim: "the last step should have completed the task", observation: observation,
                generation: generation)
            return
        }
        while let candidate = candidates.first {
            candidates.removeFirst()
            switch GuideCandidateAssessor.assess(candidate, on: observation) {
            case .strong:
                delegate?.guideTrace(.candidate(verdict: "strong \(candidate.source)"))
                await present(
                    candidate.step, observation: observation, source: candidate.source,
                    pointIsFresh: false, headsUp: nil, generation: generation)
                return
            case .medium:
                delegate?.guideTrace(.candidate(verdict: "medium \(candidate.source)"))
                await raceChecker(
                    candidate, observation: observation, note: note, generation: generation)
                return
            case .reject(let reason):
                delegate?.guideTrace(.candidate(verdict: "rejected (\(reason))"))
                continue
            }
        }
        await plan(from: observation, note: note, escalate: false, generation: generation)
    }

    /// The scout started during the last step and hasn't answered: whichever of it and a fresh
    /// plan is usable first wins.
    private func raceScout(
        _ scout: Task<[GuideCandidate], Never>, observation: GuideObservation, note: String?,
        generation: Int
    ) async {
        enum Winner {
            case scout([GuideCandidate])
            case planner(GuidePlannerReply?)
        }
        let plannerRequest = plannerRequest(role: .planner, observation: observation, note: note)
        startFiller(Self.planningFillers)
        let winner: Winner = await withTaskGroup(of: Winner.self) { group in
            group.addTask { await .scout(scout.value) }
            group.addTask { [weak self] in
                await .planner(self?.runPlanner(plannerRequest))
            }
            var result: Winner = .planner(nil)
            while let next = await group.next() {
                switch next {
                case .scout(let predicted):
                    if predicted.isEmpty, await self.scoutExpectsFinish {
                        group.cancelAll()
                        return .scout([])
                    }
                    let usable = predicted.first {
                        GuideCandidateAssessor.assess($0, on: observation) == .strong
                    }
                    for candidate in predicted {
                        let verdict = GuideCandidateAssessor.assess(candidate, on: observation)
                        await self.delegate?.guideTrace(.candidate(verdict: "raced \(verdict)"))
                    }
                    if let usable {
                        result = .scout([usable])
                        group.cancelAll()
                        return result
                    }
                case .planner:
                    result = next
                    group.cancelAll()
                    return result
                }
            }
            return result
        }
        guard generation == self.generation else { return }
        let expectsFinish = scoutExpectsFinish
        dropScout()
        switch winner {
        case .scout(let predicted) where predicted.isEmpty && expectsFinish:
            await verifyGoal(
                claim: "the last step should have completed the task", observation: observation,
                generation: generation)
        case .scout(let predicted):
            delegate?.guideTrace(.candidate(verdict: "strong scout (raced)"))
            await present(
                predicted[0].step, observation: observation, source: "scout", pointIsFresh: false,
                headsUp: nil, generation: generation)
        case .planner(let reply):
            await handlePlannerReply(
                reply, observation: observation, escalated: false, generation: generation)
        }
    }

    /// A plausible prediction: the checker confirms it while the planner works; first usable
    /// answer wins.
    private func raceChecker(
        _ candidate: GuideCandidate, observation: GuideObservation, note: String?,
        generation: Int
    ) async {
        guard let ledger else { return }
        enum Winner {
            case checker(ok: Bool, point: CGPoint?)
            case planner(GuidePlannerReply?)
        }
        let checkRequest = GuideModelRequest(
            role: .checker, system: GuideAgents.candidateCheckSystem,
            prompt: GuideAgents.candidateCheckPrompt(
                ledger: ledger, candidate: candidate.step, observation: observation),
            imageJPEG: observation.imageJPEG, maxTokens: Self.replyTokenLimit,
            timeoutSeconds: settings.checkerTimeoutSeconds)
        let plannerRequest = plannerRequest(role: .planner, observation: observation, note: note)
        startFiller(Self.planningFillers)
        let winner: Winner = await withTaskGroup(of: Winner.self) { group in
            group.addTask { [weak self] in
                let verdict = await self?.runModel(checkRequest) {
                    GuideAgents.candidateCheck(in: $0)
                }
                return .checker(ok: verdict?.ok ?? false, point: verdict?.point)
            }
            group.addTask { [weak self] in await .planner(self?.runPlanner(plannerRequest)) }
            var result: Winner = .planner(nil)
            while let next = await group.next() {
                if case .checker(let ok, _) = next, !ok { continue }
                result = next
                group.cancelAll()
                break
            }
            return result
        }
        guard generation == self.generation else { return }
        switch winner {
        case .checker(_, let point):
            var step = candidate.step
            step.targetPointNorm1000 = point
            delegate?.guideTrace(.candidate(verdict: "confirmed by checker"))
            await present(
                step, observation: observation, source: "\(candidate.source)+checker",
                pointIsFresh: point != nil, headsUp: nil, generation: generation)
        case .planner(let reply):
            await handlePlannerReply(
                reply, observation: observation, escalated: false, generation: generation)
        }
    }

    private func plan(
        from observation: GuideObservation, note: String?, escalate: Bool, generation: Int
    ) async {
        guard generation == self.generation else { return }
        phase = .thinking
        delegate?.guideStatus(escalate ? "Taking a closer look" : "Working out the next step")
        startFiller(Self.planningFillers)
        let request = plannerRequest(
            role: escalate ? .fixer : .planner, observation: observation, note: note)
        let reply = await runPlanner(request)
        guard generation == self.generation else { return }
        await handlePlannerReply(
            reply, observation: observation, escalated: escalate, generation: generation)
    }

    private func handlePlannerReply(
        _ reply: GuidePlannerReply?, observation: GuideObservation, escalated: Bool,
        generation: Int
    ) async {
        guard generation == self.generation else { return }
        switch reply {
        case nil, .wait?:
            troubles += 1
            delegate?.guideTrace(.recovery(reason: "planner reply unusable (\(troubles))"))
            if troubles <= 1 {
                let fresh = await environment.observe(.full, settle: true)
                await plan(
                    from: fresh, note: "The last reply couldn't be used; answer in the format.",
                    escalate: false, generation: generation)
            } else if troubles == 2 {
                let fresh = await environment.observe(.full, settle: true)
                await plan(from: fresh, note: nil, escalate: true, generation: generation)
            } else {
                ask(
                    "I couldn't work out the next step. Try again from this screen?",
                    options: ["Try again", "Stop guiding"], purpose: .retry)
            }
        case .step(let step, let risk, let modelHeadsUp, let remaining)?:
            estimatedRemaining = remaining
            // A check that is already true doesn't mean the step is done (an open panel can
            // already show "File type"): the planner just chose it on this screen, so show it;
            // `predicateIsUseless` then relies on the click making the app react.
            await present(
                step, observation: observation, source: escalated ? "fixer" : "planner",
                pointIsFresh: true,
                headsUp: GuideRisk.headsUp(for: step, risk: risk, modelHeadsUp: modelHeadsUp),
                generation: generation)
        case .ask(let question, let options)?:
            troubles = 0
            ask(question, options: options, purpose: .model)
        case .done(let evidence)?:
            await verifyGoal(claim: evidence, observation: observation, generation: generation)
        case .stuck(let reason)?:
            ledger?.recordNote("Stuck: \(reason)")
            delegate?.guideTrace(.recovery(reason: "stuck: \(reason)"))
            if !escalated {
                await plan(from: observation, note: nil, escalate: true, generation: generation)
            } else {
                ask(
                    "I'm stuck: \(reason) What should we do?",
                    options: ["Try again from here", "Stop guiding"], purpose: .retry)
            }
        }
    }

    private func verifyGoal(claim: String, observation: GuideObservation, generation: Int) async {
        guard let ledger else { return }
        delegate?.guideStatus("Checking it's all done")
        let request = GuideModelRequest(
            role: .checker, system: GuideAgents.goalCheckSystem,
            prompt: GuideAgents.goalCheckPrompt(
                ledger: ledger, claim: claim, observation: observation),
            imageJPEG: observation.imageJPEG, maxTokens: Self.replyTokenLimit,
            timeoutSeconds: settings.checkerTimeoutSeconds)
        let verdict = await runModel(request) { GuideAgents.goalCheck(in: $0) }
        guard generation == self.generation else { return }
        if verdict?.reached != false {
            finish()
            return
        }
        goalMisses += 1
        if goalMisses <= 1 {
            await plan(
                from: observation,
                note: "Not finished yet: \(verdict?.missing ?? "the result isn't visible").",
                escalate: false, generation: generation)
        } else {
            ask(
                "It looks finished to me. Anything else?",
                options: ["That's everything", "Keep going"], purpose: .confirmFinish)
        }
    }

    private func finish() {
        stopFiller()
        let steps = completedSteps
        cancelEverything()
        phase = .finished
        active = nil
        delegate?.guideClearStep()
        delegate?.guideFinished(steps: steps)
    }

    private func end(saying line: String) {
        delegate?.guideSpeak(line)
        stop()
    }

    // MARK: - Presenting a step

    private func present(
        _ step: WalkthroughStep, observation: GuideObservation, source: String,
        pointIsFresh: Bool, headsUp: String?, generation: Int, preface: String? = nil,
        isRepeat: Bool = false, speaks: Bool = true
    ) async {
        guard generation == self.generation else { return }
        while isSuspended, generation == self.generation {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == self.generation, let delegate else { return }
        // A predicted step uses up one of the planner's expected steps.
        if !isRepeat, source != "planner", source != "fixer", source != "again" {
            estimatedRemaining = estimatedRemaining.map { max(0, $0 - 1) }
        }
        let number = completedSteps.count + 1
        stopFiller()
        delegate.guideStatus(nil)
        var leadIn: String?
        if speaks, !isRepeat, source != "again" {
            if number == 1 {
                leadIn = "Here's the first step."
            } else {
                leadIn = Self.leadIns[leadInIndex % Self.leadIns.count]
                leadInIndex += 1
            }
        }
        let result = await delegate.guidePresent(
            GuidePresentation(
                step: step, number: number,
                estimatedTotal: estimatedRemaining.map { number + $0 }, leadIn: leadIn,
                preface: preface,
                headsUp: headsUp, isRepeat: isRepeat, speaks: speaks,
                pointIsFresh: pointIsFresh, observation: observation))
        guard generation == self.generation else { return }
        switch result {
        case .missing:
            troubles += 1
            let name = step.target?.name ?? step.label ?? step.instruction
            ledger?.recordNote("\"\(name)\" wasn't on screen for \"\(step.instruction)\"")
            delegate.guideTrace(.recovery(reason: "control missing: \(name)"))
            let fresh = await environment.observe(.full, settle: true)
            guard generation == self.generation else { return }
            await plan(
                from: fresh,
                note: "The control \"\(name)\" isn't on screen. Use what is actually visible.",
                escalate: troubles >= 2, generation: generation)
        case .shown(let frame, let foundBy):
            troubles = 0
            let field = step.target.flatMap { target in
                observation.snapshot.flatMap {
                    AccessibilityMatcher.bestMatch(for: target, in: $0, visibleArea: nil)
                }
            }
            active = ActiveStep(
                step: step, number: number, presentedAt: Date(), targetFrame: frame,
                foundByAccessibility: foundBy == "accessibility",
                predicateIsUseless: step.kind != .type && observation.evaluate(step.done) == true,
                baselineFieldValue: field?.value, bundleIdentifier: observation.bundleIdentifier,
                appName: observation.appName,
                dialogCount: observation.snapshot.map {
                    WalkthroughNavigator.dialogs(in: $0).count
                } ?? 0, baselineFingerprint: Self.fingerprint(observation),
                presentedObservation: observation)
            phase = .watching
            delegate.guideTrace(
                .presented(
                    number: number, source: source,
                    millisecondsSinceUserAction: lastUserActionAt.map {
                        Int(Date().timeIntervalSince($0) * 1000)
                    }))
            startWatching(step)
            startScout(after: step, observation: observation)
        }
    }

    /// Shows the current step again on a fresh screen (after a pause, a question, "repeat").
    private func represent(preface: String?, speaks: Bool, isRepeat: Bool) {
        guard let active else { return }
        let step = active.step
        stopWatching()
        generation += 1
        let currentGeneration = generation
        thinkTask = Task { [weak self] in
            guard let self else { return }
            let observation = await self.environment.observe(.full, settle: true)
            await self.present(
                step, observation: observation, source: "again", pointIsFresh: false,
                headsUp: nil, generation: currentGeneration, preface: preface,
                isRepeat: isRepeat, speaks: speaks)
        }
    }

    // MARK: - The scout

    private func startScout(after step: WalkthroughStep, observation: GuideObservation) {
        guard let ledger, step.kind != .observe else { return }
        dropScout()
        guard candidates.isEmpty else { return }
        let request = GuideModelRequest(
            role: .scout, system: GuideAgents.scoutSystem,
            prompt: GuideAgents.scoutPrompt(
                ledger: ledger, current: step, observation: observation,
                openApps: environment.openAppNames()),
            imageJPEG: observation.imageJPEG, maxTokens: Self.replyTokenLimit,
            timeoutSeconds: settings.scoutTimeoutSeconds)
        scoutGeneration = generation
        scoutFinished = false
        let scoutStartedFor = generation
        scoutTask = Task { [weak self] in
            guard let self else { return [] }
            let text = await self.runModelText(request)
            let predicted = text.map(GuideAgents.scoutCandidates(in:)) ?? []
            // Kept for the step after this one, whenever it starts.
            if self.scoutGeneration == scoutStartedFor {
                self.candidates = predicted
                self.scoutExpectsFinish =
                    predicted.isEmpty && text.map(GuideAgents.scoutPredictsFinish(in:)) == true
                self.scoutFinished = true
            }
            return predicted
        }
    }

    /// The scout's predictions no longer apply (the task went another way).
    private func dropScout() {
        scoutTask?.cancel()
        scoutTask = nil
        scoutGeneration = -1
        scoutFinished = true
        scoutExpectsFinish = false
        candidates = candidates.filter { $0.source == "saved" }
    }

    // MARK: - Watching the user

    private func startWatching(_ step: WalkthroughStep) {
        stopWatching()
        let currentGeneration = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.settings.pollSeconds ?? 1))
                guard let self, !Task.isCancelled, self.generation == currentGeneration else {
                    return
                }
                self.scheduleEvaluation(after: 0, fromUser: false)
            }
        }
        if !isSuspended { startHints(for: step) }
        scheduleEvaluation(after: 0.4, fromUser: false)
    }

    private func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
        hintTask?.cancel()
        hintTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        typingIdleTask?.cancel()
        typingIdleTask = nil
        checkTask?.cancel()
        checkTask = nil
        evaluateAgain = nil
    }

    private func startHints(for step: WalkthroughStep) {
        hintTask?.cancel()
        let currentGeneration = generation
        let nudgeAfter = settings.nudgeSeconds
        let checkAfter = settings.stuckCheckSeconds
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(nudgeAfter))
            guard let self, !Task.isCancelled, self.generation == currentGeneration,
                self.phase == .watching, self.secondsSinceUserAction >= 8
            else { return }
            self.delegate?.guideNudge()
            try? await Task.sleep(for: .seconds(max(0, checkAfter - nudgeAfter)))
            guard !Task.isCancelled, self.generation == currentGeneration,
                self.phase == .watching, self.secondsSinceUserAction >= 8
            else { return }
            self.requestStepCheck(
                whatHappened: "nothing has finished this step for a while", isStuckCheck: true)
        }
    }

    private var secondsSinceUserAction: Double {
        guard let lastUserActionAt else { return .infinity }
        return Date().timeIntervalSince(lastUserActionAt)
    }

    /// Clicks, keys and accessibility changes from the app's listen-only monitors.
    public func handle(_ event: GuideUserEvent) {
        guard phase == .watching || phase == .paused, var active else { return }
        let step = active.step
        switch event {
        case .screenMayHaveChanged, .appSwitched: break
        default:
            // They're still acting: a look at the screen from a moment ago is out of date.
            checkTask?.cancel()
            checkTask = nil
            lastCheckAt = .distantPast
            stopFiller()
        }
        switch event {
        case .click(let onTarget):
            lastUserActionAt = Date()
            if onTarget { active.actedOnTarget = true }
            if active.typed, !onTarget { active.committed = true }
            if onTarget, step.kind == .click || step.kind == .menu || step.kind == .drag {
                delegate?.guideClearStep()
            }
            ledger?.recordUserAction(
                onTarget
                    ? "clicked \(step.target?.name ?? "the circled control")"
                    : "clicked somewhere else")
            self.active = active
            scheduleEvaluation(after: 0.3, fromUser: true)
        case .typed:
            lastUserActionAt = Date()
            active.typed = true
            active.lastTypingAt = Date()
            self.active = active
            scheduleTypingIdle()
            scheduleEvaluation(after: 0.5, fromUser: false)
        case .returnKey, .tabKey:
            lastUserActionAt = Date()
            active.committed = true
            if step.kind == .shortcut,
                step.shortcut.flatMap(KeyboardShortcut.init(parsing:))?.key
                    == (event == .returnKey ? "return" : "tab")
            {
                active.pressedShortcut = true
            }
            ledger?.recordUserAction(event == .returnKey ? "pressed Return" : "pressed Tab")
            self.active = active
            scheduleEvaluation(after: 0.35, fromUser: true)
        case .escapeKey:
            lastUserActionAt = Date()
            scheduleEvaluation(after: 0.3, fromUser: true)
        case .shortcut(let key, let modifiers):
            lastUserActionAt = Date()
            if step.kind == .shortcut,
                step.shortcut.flatMap(KeyboardShortcut.init(parsing:))?.matches(
                    key: key, modifiers: modifiers) == true
            {
                active.pressedShortcut = true
                ledger?.recordUserAction("pressed \(step.shortcut ?? key)")
                self.active = active
            }
            scheduleEvaluation(after: 0.4, fromUser: true)
        case .screenMayHaveChanged:
            scheduleEvaluation(after: 0.25, fromUser: false)
        case .appSwitched:
            scheduleEvaluation(after: 0.3, fromUser: false)
        }
    }

    private func scheduleTypingIdle() {
        typingIdleTask?.cancel()
        let currentGeneration = generation
        let idle = settings.typingIdleSeconds
        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            guard let self, !Task.isCancelled, self.generation == currentGeneration,
                var active = self.active
            else { return }
            active.committed = true
            self.active = active
            self.scheduleEvaluation(after: 0, fromUser: true)
        }
    }

    private func scheduleEvaluation(after delay: Double, fromUser: Bool) {
        guard phase == .watching || phase == .paused else { return }
        if isEvaluating {
            evaluateAgain = (evaluateAgain ?? false) || fromUser
            return
        }
        // A user action always replaces a pending passive check; a poll never delays one.
        if evaluationTask != nil, !fromUser, delay == 0 { return }
        evaluationTask?.cancel()
        let currentGeneration = generation
        evaluationTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.evaluationTask = nil
            self.isEvaluating = true
            await self.evaluate(fromUser: fromUser, generation: currentGeneration)
            self.isEvaluating = false
            if let again = self.evaluateAgain, self.generation == currentGeneration {
                self.evaluateAgain = nil
                self.scheduleEvaluation(after: 0.15, fromUser: again)
            }
        }
    }

    private func evaluate(fromUser: Bool, generation: Int) async {
        guard var active else { return }
        let observation = await environment.observe(.tree, settle: false)
        guard generation == self.generation, self.active != nil else { return }
        active = self.active ?? active
        let step = active.step

        // Away in another app: hold the step until they come back (D75).
        if phase == .paused {
            if observation.bundleIdentifier == active.bundleIdentifier {
                phase = .watching
                delegate?.guidePaused(false, appName: active.appName)
                represent(preface: nil, speaks: false, isRepeat: false)
            }
            return
        }
        if !observation.isChalkInFront, let expected = active.bundleIdentifier,
            let current = observation.bundleIdentifier, current != expected
        {
            if Date().timeIntervalSince(active.presentedAt) < settings.pauseGraceSeconds
                || belongsToTask(appName: observation.appName)
            {
                // The step opened it, or the task needs it: follow along.
                active.bundleIdentifier = current
                active.appName = observation.appName
                self.active = active
            } else {
                phase = .paused
                hintTask?.cancel()
                delegate?.guideClearStep()
                delegate?.guidePaused(true, appName: active.appName)
                return
            }
        }

        let result = active.predicateIsUseless ? nil : observation.evaluate(step.done)
        if step.kind == .type {
            if let field = step.target, active.typed, !active.committed,
                let focused = observation.snapshot?.focusedNode,
                !focused.names.contains(where: {
                    (FuzzyTextMatch.rank(candidate: $0, wanted: field.name) ?? 9) <= 2
                })
            {
                // Focus moved on from the field they typed in: that's finishing it.
                active.committed = true
                self.active = active
            }
            let fieldValue = step.target.flatMap { target in
                observation.snapshot.flatMap {
                    AccessibilityMatcher.bestMatch(for: target, in: $0, visibleArea: nil)?.value
                }
            }
            let changed = fieldValue != active.baselineFieldValue
            let exactValue: Bool = {
                if case .valueContains? = step.done { return true }
                return false
            }()
            if result == true, changed || exactValue, exactValue || active.committed {
                await confirmDone(
                    how: exactValue ? "typed the value" : "typed and moved on",
                    generation: generation)
                return
            }
            if result == nil || result == false, active.committed, fromUser {
                requestStepCheck(whatHappened: "typed and moved on")
            }
            return
        }
        if result == true {
            await confirmDone(how: "the app shows it", generation: generation)
            return
        }
        // They clicked the circled control and the app visibly reacted (a window, a menu,
        // focus, a new page): that is the step, even when its predicate can't say so.
        // A shortcut step needs no seen key press: macOS swallows some (⌘Space never reaches
        // Chalk), and the screen reacting (Spotlight opening) is the step.
        let reacted = Self.fingerprint(observation) != active.baselineFingerprint
        if result != true, reacted, step.kind == .shortcut,
            Date().timeIntervalSince(active.presentedAt) > 0.3
        {
            await confirmDone(
                how: "the shortcut's effect appeared", generation: generation, trustAction: true)
            return
        }
        if result != true, active.actedOnTarget || active.pressedShortcut,
            step.kind == .click || step.kind == .menu,
            observation.snapshot?.isUsable == true, reacted
        {
            await confirmDone(
                how: "did it; the screen changed", generation: generation, trustAction: true)
            return
        }

        // A dialog the step didn't expect: plan past it.
        if let snapshot = observation.snapshot {
            let dialogs = WalkthroughNavigator.dialogs(in: snapshot)
            if dialogs.count > active.dialogCount, let dialog = dialogs.last,
                !(step.target.map {
                    AccessibilityMatcher.bestMatch(for: $0, in: snapshot, visibleArea: dialog.frame)
                        != nil
                } ?? false)
            {
                let text = WalkthroughNavigator.dialogText(dialog, in: snapshot)
                rethink(note: "A dialog appeared: \(text)")
                return
            }
        }

        // Its control went away without the step finishing: the screen moved on.
        if active.foundByAccessibility, let query = step.target,
            let snapshot = observation.snapshot, snapshot.isUsable
        {
            if AccessibilityMatcher.bestMatch(for: query, in: snapshot, visibleArea: nil) != nil {
                active.targetMissingSince = nil
            } else if let since = active.targetMissingSince {
                if Date().timeIntervalSince(since) >= settings.targetGoneSeconds {
                    active.targetMissingSince = nil
                    self.active = active
                    requestStepCheck(whatHappened: "the circled control went away")
                    return
                }
            } else {
                active.targetMissingSince = Date()
                scheduleEvaluation(after: settings.targetGoneSeconds + 0.1, fromUser: false)
            }
            self.active = active
        }

        // The app can't tell (no tree, or a predicate that doesn't fit what happened) after
        // they acted: the checker looks.
        if fromUser {
            requestStepCheck(whatHappened: ledger?.lastUserAction ?? "the user acted")
        }
    }

    /// The task may legitimately move to this app (it's named in the goal, the step or a
    /// note), so switching to it is following along, not leaving.
    private func belongsToTask(appName: String?) -> Bool {
        guard let appName, !appName.isEmpty else { return false }
        if appName == "Dock" || appName == "Spotlight" { return true }
        var texts = [ledger?.goal ?? ""] + completedSteps.map(\.instruction)
        if let step = active?.step {
            texts += [step.app, step.instruction, step.target?.name, step.doneJSON].compactMap {
                $0
            }
        }
        return texts.contains { $0.localizedCaseInsensitiveContains(appName) }
    }

    /// The predicate says done: take one settled look (the next step needs it anyway) and
    /// move on if it still holds. Replaces reading twice.
    private func confirmDone(how: String, generation: Int, trustAction: Bool = false) async {
        guard let step = active?.step else { return }
        stopWatching()
        let settled = await environment.observe(.full, settle: true)
        guard generation == self.generation, let active else { return }
        let stillDone: Bool = {
            if step.kind == .type || trustAction { return true }
            return active.predicateIsUseless || settled.evaluate(step.done) != false
        }()
        if stillDone {
            await stepDone(how: how, observation: settled, generation: generation)
        } else {
            startWatching(step)
        }
    }

    private func stepDone(how: String, observation: GuideObservation, generation: Int) async {
        completeStep(how: how, generation: generation) { [weak self] nextGeneration in
            await self?.advance(from: observation, note: nil, generation: nextGeneration)
        }
    }

    /// Records the current step as done and runs what comes next in a fresh task (never the
    /// task that noticed it, which finishing the step cancels).
    private func completeStep(
        how: String, generation: Int, then next: @escaping @MainActor (Int) async -> Void
    ) {
        guard generation == self.generation, let active else { return }
        checkTask = nil
        stopWatching()
        ledger?.recordOutcome(active.step.instruction, how: how)
        ledger?.clearNotes()
        completedSteps.append(active.step)
        delegate?.guideTrace(.stepDone(number: active.number, how: how))
        delegate?.guideClearStep()
        self.active = nil
        self.generation += 1
        let nextGeneration = self.generation
        thinkTask = Task { await next(nextGeneration) }
    }

    /// Leaves the current step and plans from a fresh, settled screen.
    private func rethink(note: String) {
        stopWatching()
        delegate?.guideClearStep()
        active = nil
        dropScout()
        generation += 1
        let currentGeneration = generation
        ledger?.recordNote(note)
        delegate?.guideTrace(.recovery(reason: note))
        phase = .thinking
        thinkTask = Task { [weak self] in
            guard let self else { return }
            let observation = await self.environment.observe(.full, settle: true)
            await self.plan(
                from: observation, note: note, escalate: false, generation: currentGeneration)
        }
    }

    /// The model judges the step from the screen (D86): one planner call that either says
    /// "not yet" (with help) or, the step being done, gives the next step. Local signals only
    /// decide when to look. A scout prediction that has just come true settles it with no call.
    private func requestStepCheck(whatHappened: String, isStuckCheck: Bool = false) {
        guard checkTask == nil, let step = active?.step,
            Date().timeIntervalSince(lastCheckAt) >= settings.minimumSecondsBetweenChecks
        else { return }
        lastCheckAt = Date()
        let currentGeneration = generation
        if !isStuckCheck { startFiller(Self.checkingFillers) }
        checkToken += 1
        let token = checkToken
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.checkToken == token { self.checkTask = nil } }
            let observation = await self.environment.observe(.full, settle: true)
            guard !Task.isCancelled, self.generation == currentGeneration,
                self.phase == .watching, let active = self.active
            else { return }
            if let candidate = self.candidates.first(where: { candidate in
                guard let precondition = candidate.precondition else { return false }
                return active.presentedObservation.evaluate(precondition) == false
                    && GuideCandidateAssessor.assess(candidate, on: observation) == .strong
            }) {
                self.candidates.removeAll { $0 == candidate }
                self.delegate?.guideTrace(.candidate(verdict: "came true"))
                self.completeStep(how: "its result appeared", generation: currentGeneration) {
                    [weak self] nextGeneration in
                    await self?.present(
                        candidate.step, observation: observation, source: candidate.source,
                        pointIsFresh: false, headsUp: nil, generation: nextGeneration)
                }
                return
            }
            let request = self.plannerRequest(
                role: .planner, observation: observation,
                note: GuideAgents.judgeNote(
                    step: step, lastAction: self.ledger?.lastUserAction ?? whatHappened,
                    isStuck: isStuckCheck))
            let reply = await self.runPlanner(request)
            guard !Task.isCancelled, self.generation == currentGeneration,
                self.phase == .watching
            else { return }
            self.stopFiller()
            self.checkTask = nil
            switch reply {
            case .wait(let advice)?:
                if let advice, self.active?.hasGivenAdvice == false {
                    self.active?.hasGivenAdvice = true
                    self.delegate?.guideSpeak(advice)
                } else if isStuckCheck {
                    self.delegate?.guideSpeak(
                        "Take your time. Say I'm lost if your screen looks different.")
                }
            case nil:
                // No usable answer: a click on the circle that the user made is trusted.
                if active.actedOnTarget || active.pressedShortcut {
                    self.completeStep(how: "did it (not checked)", generation: currentGeneration) {
                        [weak self] nextGeneration in
                        await self?.advance(
                            from: observation, note: nil, generation: nextGeneration)
                    }
                }
            case let reply?:
                // Anything but "wait": the step is done, and the reply is what comes next.
                self.completeStep(how: "the planner saw it done", generation: currentGeneration) {
                    [weak self] nextGeneration in
                    await self?.handlePlannerReply(
                        reply, observation: observation, escalated: false,
                        generation: nextGeneration)
                }
            }
        }
    }

    // MARK: - Fillers (D86)

    /// A short spoken line if Chalk is still thinking after `fillerAfterSeconds`, and one more
    /// if it takes much longer. Never the same line twice in a row.
    private func startFiller(_ lines: [String]) {
        fillerTask?.cancel()
        let after = settings.fillerAfterSeconds
        fillerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard let self, !Task.isCancelled else { return }
            self.sayFiller(from: lines)
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self.sayFiller(from: ["Still working on it, nearly there."])
        }
    }

    private func sayFiller(from lines: [String]) {
        // Never over the user talking or a question being answered.
        guard !isSuspended else { return }
        let line = lines.filter { $0 != lastFiller }.randomElement() ?? lines[0]
        lastFiller = line
        delegate?.guideFiller(line)
    }

    private func stopFiller() {
        fillerTask?.cancel()
        fillerTask = nil
    }

    /// A coarse summary of the screen: window, page, focus, dialogs, selection, size of the
    /// tree. Different after a click means the app reacted.
    static func fingerprint(_ observation: GuideObservation) -> String {
        guard let snapshot = observation.snapshot else { return observation.bundleIdentifier ?? "" }
        let selected = snapshot.nodes.filter(\.isSelected).compactMap(\.names.first).sorted()
        return [
            observation.bundleIdentifier ?? "", snapshot.focusedWindowTitle ?? "",
            snapshot.documentURL ?? "", snapshot.focusedNode?.names.first ?? "",
            String(WalkthroughNavigator.dialogs(in: snapshot).count),
            String(snapshot.nodes.count / 4), selected.joined(separator: ","),
        ].joined(separator: "|")
    }

    // MARK: - Questions to the user

    private func ask(_ question: String, options: [String], purpose: AskPurpose) {
        stopFiller()
        stopWatching()
        phase = .asking
        pendingAsk = (question, options, purpose)
        delegate?.guideStatus(nil)
        delegate?.guideTrace(.asked(question: question, options: options))
        delegate?.guideAsk(question: question, options: options)
    }

    /// A tapped option on the question card.
    public func choose(_ option: String) {
        guard let pending = pendingAsk, pending.options.contains(option) else { return }
        isSuspended = false
        pendingAsk = nil
        delegate?.guideHideQuestion()
        switch pending.purpose {
        case .model:
            ledger?.recordDecision("\(pending.question) → \(option)")
            rethink(note: "The user chose: \(option)")
        case .retry:
            if option.lowercased().hasPrefix("stop") {
                end(saying: "Okay, stopping here.")
            } else {
                troubles = 0
                rethink(note: "Try again from the current screen.")
            }
        case .confirmFinish:
            if option == "That's everything" {
                finish()
            } else {
                goalMisses = 0
                rethink(note: "The user says it isn't finished yet.")
            }
        }
    }

    /// A spoken answer while a question card is up. Exact names and numbers match locally;
    /// anything else goes to the checker, and an answer that matches no option is taken as the
    /// user's own direction. Returns false when no question is pending.
    public func answer(_ transcript: String) -> Bool {
        guard let pending = pendingAsk else { return false }
        isSuspended = false
        let decision = AdaptiveDecision(question: pending.question, options: pending.options)
        if let option = decision.answer(matching: transcript) {
            choose(option)
            return true
        }
        let currentGeneration = generation
        let request = GuideModelRequest(
            role: .checker, system: GuideAgents.answerSystem,
            prompt: GuideAgents.answerPrompt(
                question: pending.question, options: pending.options, transcript: transcript),
            imageJPEG: nil, maxTokens: Self.replyTokenLimit,
            timeoutSeconds: settings.checkerTimeoutSeconds)
        Task { [weak self] in
            guard let self else { return }
            let interpreted = await self.runModel(request) { GuideAgents.answer(in: $0) }
            guard self.generation == currentGeneration, self.pendingAsk != nil else { return }
            if let index = interpreted?.option, (1...pending.options.count).contains(index) {
                self.choose(pending.options[index - 1])
            } else if pending.purpose == .model {
                self.pendingAsk = nil
                self.delegate?.guideHideQuestion()
                self.ledger?.recordDecision("\(pending.question) → user said: \(transcript)")
                self.rethink(note: "The user answered: \(transcript)")
            } else {
                self.delegate?.guideSpeak("Say \(pending.options.joined(separator: ", or ")).")
            }
        }
        return true
    }

    // MARK: - Commands (§4.2.6 step 8)

    /// Returns false when the command needs an answer from the model (a "why" with no reason).
    @discardableResult
    public func handle(command: WalkthroughCommand) -> Bool {
        guard isActive else { return false }
        isSuspended = false
        if command == .stop {
            end(saying: "Okay, stopping here.")
            return true
        }
        if pendingAsk != nil { return true }
        switch command {
        case .next:
            guard active != nil else { return true }
            lastUserActionAt = Date()
            let currentGeneration = generation
            stopWatching()
            thinkTask = Task { [weak self] in
                guard let self else { return }
                let observation = await self.environment.observe(.full, settle: true)
                await self.stepDone(
                    how: "the user said done", observation: observation,
                    generation: currentGeneration)
            }
        case .repeatStep:
            represent(preface: nil, speaks: true, isRepeat: true)
        case .skip:
            let skipped = active?.step.instruction ?? "the current step"
            rethink(note: "The user skipped \"\(skipped)\"; carry on without it.")
        case .back:
            let previous = completedSteps.last?.instruction ?? "the previous step"
            rethink(note: "The user wants to go back and redo \"\(previous)\".")
        case .replanHere:
            rethink(
                note:
                    "The user is lost or the screen doesn't match. Give the one next action from what is visible and say where it is."
            )
        case .startOver:
            if let goal = ledger?.goal { ledger = GuideLedger(goal: goal) }
            completedSteps = []
            rethink(note: "Start the task again from the beginning.")
        case .why:
            guard let why = active?.step.why else { return false }
            delegate?.guideSpeak(why)
        case .stop:
            break
        }
        return true
    }

    // MARK: - Model calls

    private func plannerRequest(role: GuideRole, observation: GuideObservation, note: String?)
        -> GuideModelRequest
    {
        GuideModelRequest(
            role: role,
            system: role == .fixer ? GuideAgents.fixerSystem : GuideAgents.plannerSystem,
            prompt: GuideAgents.plannerPrompt(
                ledger: ledger ?? GuideLedger(goal: ""), observation: observation,
                openApps: environment.openAppNames(), note: note),
            imageJPEG: observation.imageJPEG, maxTokens: Self.replyTokenLimit,
            timeoutSeconds: role == .fixer
                ? settings.fixerTimeoutSeconds : settings.plannerTimeoutSeconds)
    }

    private func runPlanner(_ request: GuideModelRequest) async -> GuidePlannerReply? {
        await runModel(request) { GuideAgents.plannerReply(in: $0) }
    }

    /// Streams a helper's reply and returns as soon as a usable JSON object arrives (the rest of
    /// the stream is abandoned, which aborts the call).
    private func runModel<Result>(
        _ request: GuideModelRequest, parse: (String) -> Result?
    ) async -> Result? {
        let startedAt = Date()
        var scanner = JSONObjectScanner.Incremental()
        var text = ""
        var result: Result?
        for await delta in environment.streamModel(request) {
            if Task.isCancelled { break }
            text += delta
            for object in scanner.feed(delta) {
                if let compact = object.compactJSONText, let parsed = parse(compact) {
                    result = parsed
                    break
                }
            }
            if result != nil { break }
        }
        if result == nil, !Task.isCancelled { result = parse(text) }
        if result == nil, !Task.isCancelled {
            delegate?.guideTrace(
                .unusableReply(role: request.role, excerpt: String(text.prefix(300))))
        }
        delegate?.guideTrace(
            .modelCall(
                role: request.role, milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                succeeded: result != nil))
        return result
    }

    private func runModelText(_ request: GuideModelRequest) async -> String? {
        let startedAt = Date()
        var text = ""
        for await delta in environment.streamModel(request) {
            if Task.isCancelled { break }
            text += delta
        }
        let succeeded = !text.isEmpty && !Task.isCancelled
        delegate?.guideTrace(
            .modelCall(
                role: request.role, milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                succeeded: succeeded))
        return succeeded ? text : nil
    }
}
