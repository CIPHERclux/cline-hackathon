//
//  WalkthroughController.swift
//  Chalk
//
//  Guided walkthroughs (§4.2.6, D86): the app side of ChalkCore's GuideCoordinator. The
//  coordinator decides what happens (planner, scout, checker and fixer helpers reading one
//  shared ledger); this controller is its eyes, hands and voice on the real Mac:
//  - observing: the front app's accessibility tree (cheap, for "is it done yet"), and on demand a
//    settled screenshot plus OCR words for apps without a tree;
//  - presenting: find the step's control (tree → Dock → the planner's point → OCR → one quick
//    model look), circle it and say the step at once;
//  - watching: listen-only clicks and keys, accessibility notifications, app switches, all only
//    while a walkthrough the user started is running (§6.5);
//  - helper calls: the engine's fast `complete` path, the slot's models in order, with a deadline
//    and an abort when the coordinator stops listening.
//  Chalk never clicks or types for the user (§3.5).
//

import AppKit
import ChalkCore
import os

@MainActor
final class WalkthroughController: GuideEnvironment, GuideDelegate {
    private static let log = Logger(subsystem: "com.chalk.app", category: "walkthrough")

    /// The step's control may still be animating in: a few quick retries before fallbacks.
    static let accessibilityRetries = 3
    static let accessibilityRetrySeconds = 0.25
    static let locateTimeoutSeconds = 20.0
    static let longestAppWaitSeconds = 3.0
    /// Speech never waits longer than this for the circle.
    static let speakBeforeCircleAfterSeconds = 0.5
    /// Settling: screenshots this far apart that differ by less than `settledFraction` mean the
    /// screen has stopped changing (a page loaded, a menu finished opening).
    static let settleIntervalSeconds = 0.15
    static let settleLongestSeconds = 1.2
    static let settledFraction = 0.008

    private let engineHost: TutorEngineHost
    private let userData: UserDataStore
    weak var turnController: TeachingTurnController?

    let hud = WalkthroughHUDPanel()
    let recap = WalkthroughRecapPanel()
    private let questionPanel = WorkflowDecisionPanel()
    private lazy var coordinator: GuideCoordinator = {
        let coordinator = GuideCoordinator(environment: self)
        coordinator.delegate = self
        return coordinator
    }()

    private var goal = ""
    private var appName: String?
    private var savedHowToIdentifier: UUID?
    /// Kept for TeachingTurnController's turn bookkeeping; plans are no longer streamed.
    private(set) var planToken = 0
    let isPlanStreaming = false
    private var isAnsweringQuestion = false
    private var questionToken = 0

    /// Screenshots behind recent observations, so a step is drawn on the screen it was planned on.
    private var capturesByObservation: [(UUID, ScreenCaptureResult)] = []

    // The step on screen.
    private var stepTargetRectInAppKitGlobal: CGRect?
    private var stepTargetRegion: TargetDescriptor?
    private var stepCapture: ScreenCaptureResult?
    private var earlySpeechTask: Task<Void, Never>?
    private var spokeCurrentStepEarly = false
    /// The last thing said was a filler: the step's speech queues after it instead of cutting
    /// it off, so they never overlap or clip.
    private var lastSpeechWasFiller = false

    // Watching (only while a walkthrough runs).
    private var inputMonitor: Any?
    private var mouseDownLocation: CGPoint?
    private var changeObserver: AccessibilityService.ChangeObserver?
    private var observedProcessIdentifier: pid_t?
    private var workspaceObserver: NSObjectProtocol?

    init(engineHost: TutorEngineHost, userData: UserDataStore) {
        self.engineHost = engineHost
        self.userData = userData
        hud.onBack = { [weak self] in _ = self?.handle(.back) }
        hud.onSkip = { [weak self] in _ = self?.handle(.skip) }
        hud.onStop = { [weak self] in _ = self?.handle(.stop) }
    }

    var isActive: Bool { coordinator.isActive }

    // MARK: - Starting

    /// "Guide me…": guide from the current screen. `keyDownCapture` is the screenshot taken when
    /// the talk key went down: the screen the user is asking about, already in hand.
    func start(
        goal: String, appName: String?,
        keyDownCapture: Task<ScreenCaptureResult?, Never>? = nil
    ) {
        begin(
            goal: goal, appName: appName, savedSteps: [], savedHowToIdentifier: nil,
            keyDownCapture: keyDownCapture)
    }

    /// An ordinary answer that started listing steps (a task said plainly): guide it instead.
    func adoptPlan(goal: String, appName: String?) -> Int {
        start(goal: goal, appName: appName)
        planToken += 1
        return planToken
    }

    /// A saved how-to: its steps are tried first on today's screen; the planner fills any gap.
    func run(_ howTo: SavedHowTo) {
        turnController?.stopSpeakingAndDrawing()
        begin(
            goal: howTo.title, appName: howTo.appName, savedSteps: howTo.steps,
            savedHowToIdentifier: howTo.id)
    }

    private func begin(
        goal: String, appName: String?, savedSteps: [WalkthroughStep], savedHowToIdentifier: UUID?,
        keyDownCapture: Task<ScreenCaptureResult?, Never>? = nil
    ) {
        if coordinator.isActive { coordinator.stop() }
        self.goal = goal
        self.appName = appName
        self.savedHowToIdentifier = savedHowToIdentifier
        isAnsweringQuestion = false
        recap.hide()
        questionPanel.hide()
        turnController?.annotationController.keepsStepMarks = true
        hud.model.progressText = "Step 1"
        hud.model.instruction = "Looking at your screen…"
        hud.model.shortcutSymbols = nil
        hud.model.statusText = nil
        hud.model.canGoBack = false
        hud.show(onDisplay: nil, avoiding: nil)
        startWatchingInput()
        Self.log.notice("🧭 walkthrough: start (saved steps: \(savedSteps.count))")
        guard let keyDownCapture else {
            coordinator.start(goal: goal, savedSteps: savedSteps)
            return
        }
        planToken += 1
        let token = planToken
        Task { [weak self] in
            let capture = await keyDownCapture.value
            guard let self, self.planToken == token else { return }
            let observation = await self.observation(from: capture)
            guard self.planToken == token else { return }
            self.coordinator.start(
                goal: goal, savedSteps: savedSteps, initialObservation: observation)
        }
    }

    // Plans are no longer streamed by answer turns (D86); kept for the turn controller.
    func planStepArrived(_ step: WalkthroughStep) {}
    func planTurnEnded(token: Int, wasCancelled: Bool) {}

    // MARK: - Commands and answers (§4.2.6 step 8)

    /// Returns false when the command needs a model answer (a "why" the step didn't give).
    @discardableResult
    func handle(_ command: WalkthroughCommand) -> Bool {
        guard isActive else { return false }
        Self.log.notice("🧭 walkthrough: command \(String(describing: command), privacy: .public)")
        if command != .why { turnController?.voiceOut.stop() }
        return coordinator.handle(command: command)
    }

    /// A spoken answer while a question card is up.
    func handleAdaptiveAnswer(_ transcript: String) -> Bool {
        guard isActive else { return false }
        return coordinator.answer(transcript)
    }

    // MARK: - Talk key and questions

    func userStartedTalking() {
        guard isActive else { return }
        coordinator.suspend()
        hud.model.statusText = "Listening"
    }

    /// The key was pressed but nothing was said: show the step again (the press cleared it).
    func userFinishedTalkingWithoutSpeech() {
        guard isActive, !isAnsweringQuestion else { return }
        hud.model.statusText = nil
        coordinator.resume(preface: nil, redraw: true)
    }

    func questionStarted() -> (context: String, token: Int)? {
        guard let step = coordinator.currentStep else { return nil }
        isAnsweringQuestion = true
        questionToken += 1
        coordinator.suspend()
        hud.model.statusText = "Answering"
        return (
            WalkthroughPrompts.questionContext(
                goal: goal, step: step, progress: coordinator.progressText),
            questionToken
        )
    }

    func questionTurnEnded(token: Int, wasCancelled: Bool) {
        guard token == questionToken else { return }
        isAnsweringQuestion = false
        guard isActive else { return }
        Task { [weak self] in
            while self?.turnController?.voiceOut.isSpeaking == true {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, self.isActive, !self.isAnsweringQuestion else { return }
            self.hud.model.statusText = nil
            self.coordinator.resume(preface: wasCancelled ? nil : "Back to it.", redraw: true)
        }
    }

    /// Stops without a recap (a new task, "stop", quitting).
    func end(saying line: String?) {
        turnController?.cancelWalkthroughTurnIfRunning()
        if line != nil { turnController?.voiceOut.stop() }
        if coordinator.isActive {
            coordinator.stop()
        } else {
            cleanUp()
        }
        if let line { turnController?.voiceOut.speak(SpeakAction(text: line)) }
    }

    private func cleanUp() {
        stopWatchingInput()
        questionPanel.hide()
        hud.hide()
        clearStepMarks()
        turnController?.annotationController.keepsStepMarks = false
        capturesByObservation = []
        isAnsweringQuestion = false
        planToken += 1
    }

    // MARK: - GuideEnvironment

    func observe(_ depth: GuideObservationDepth, settle: Bool) async -> GuideObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isChalkInFront = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        guard depth == .full else {
            let snapshot = await AccessibilityService.snapshotOfFrontmostApp()
            return GuideObservation(
                appName: snapshot?.appName ?? frontmost?.localizedName,
                bundleIdentifier: snapshot?.bundleIdentifier ?? frontmost?.bundleIdentifier,
                snapshot: snapshot, isChalkInFront: isChalkInFront)
        }
        let capture =
            settle ? await settledCapture() : try? await CaptureService.captureCursorDisplay()
        return await observation(from: capture)
    }

    /// A full observation from a screenshot: the tree, the image and, for apps without a tree,
    /// the words OCR reads.
    private func observation(from capture: ScreenCaptureResult?) async -> GuideObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isChalkInFront = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        let snapshot = await AccessibilityService.snapshotOfFrontmostApp()
        var visibleTexts: [GuideVisibleText] = []
        if let capture, snapshot?.isUsable != true,
            let perception = await PerceptionService.perceive(capture)
        {
            // No tree (DaVinci, a canvas): the words on screen stand in for control names.
            let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
            visibleTexts = perception.snapTargets.compactMap { mark in
                guard mark.kind == .text, let text = mark.text, !text.isEmpty else { return nil }
                return GuideVisibleText(
                    text: text,
                    frame: capture.screenSpace.nativePixelsToAccessibilityRect(
                        mark.box, mainDisplayHeight: mainDisplayHeight))
            }
        }
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        // What one click can open: the planner's shortest path, from facts not rules.
        let dockItems =
            await AccessibilityService.snapshotOfDock()?.nodes
            .filter { $0.role == "AXDockItem" }.compactMap(\.names.first) ?? []
        var observation = GuideObservation(
            appName: snapshot?.appName ?? frontmost?.localizedName,
            bundleIdentifier: snapshot?.bundleIdentifier ?? frontmost?.bundleIdentifier,
            snapshot: snapshot, visibleTexts: visibleTexts, imageJPEG: capture?.modelJPEGData,
            screenFrame: capture?.screenSpace.accessibilityVisibleArea(
                mainDisplayHeight: mainDisplayHeight) ?? .zero, dockItems: dockItems,
            isChalkInFront: isChalkInFront)
        if let capture {
            observation.identifier = UUID()
            capturesByObservation.append((observation.identifier, capture))
            capturesByObservation = Array(capturesByObservation.suffix(4))
        }
        return observation
    }

    /// Screenshots until two in a row barely differ (bounded), so a loading page or an opening
    /// menu is read once it is done.
    private func settledCapture() async -> ScreenCaptureResult? {
        let startedAt = Date()
        var previous = try? await CaptureService.captureCursorDisplay()
        var previousThumbnail = previous.flatMap { ScreenThumbnail(image: $0.nativeImage) }
        while Date().timeIntervalSince(startedAt) < Self.settleLongestSeconds {
            try? await Task.sleep(for: .seconds(Self.settleIntervalSeconds))
            guard let next = try? await CaptureService.captureCursorDisplay() else { break }
            let nextThumbnail = ScreenThumbnail(image: next.nativeImage)
            defer {
                previous = next
                previousThumbnail = nextThumbnail
            }
            if let before = previousThumbnail, let after = nextThumbnail,
                ScreenChange.between(before, after).changedFraction < Self.settledFraction
            {
                return next
            }
        }
        return previous
    }

    func streamModel(_ request: GuideModelRequest) -> AsyncStream<String> {
        let client = engineHost.client
        let router = engineHost.router
        return AsyncStream { continuation in
            let worker = Task { @MainActor in
                guard let client, let router,
                    let models = try? router.candidateModels(
                        for: request.slot, requiresVision: request.imageJPEG != nil)
                else {
                    continuation.finish()
                    return
                }
                let images =
                    request.imageJPEG.map { ["data:image/jpeg;base64,\($0.base64EncodedString())"] }
                    ?? []
                // The slot's models in order: the next one only if this one never answered.
                for model in models.prefix(2) {
                    var sessionIdentifier: String?
                    var answered = false
                    let events = await client.completeTurn(
                        slot: request.slot.rawValue, model: model, system: request.system,
                        prompt: request.prompt, imageDataURLs: images, maxTokens: request.maxTokens)
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .session(let identifier, _): sessionIdentifier = identifier
                        case .text(let delta):
                            answered = true
                            continuation.yield(delta)
                        case .error(let error):
                            Self.log.error(
                                "🧭 \(request.role.rawValue, privacy: .public) failed: \(error.kind, privacy: .public) model=\(model, privacy: .public)"
                            )
                        default: break
                        }
                    }
                    if Task.isCancelled, let sessionIdentifier {
                        await client.abort(sessionIdentifier: sessionIdentifier)
                    }
                    if answered || Task.isCancelled { break }
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

    func openAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap(\.localizedName)
    }

    // MARK: - GuideDelegate: presenting

    func guideStatus(_ text: String?) {
        hud.model.statusText = text
        if text != nil, coordinator.currentStep == nil {
            hud.model.instruction = "…"
        }
    }

    func guidePresent(_ presentation: GuidePresentation) async -> GuidePresentResult {
        let step = presentation.step
        let startedAt = Date()
        clearStepMarks()
        spokeCurrentStepEarly = false
        // If finding the control takes a moment (OCR, a model look), say the step anyway; the
        // circle joins when found.
        earlySpeechTask?.cancel()
        earlySpeechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.speakBeforeCircleAfterSeconds))
            guard let self, !Task.isCancelled else { return }
            self.spokeCurrentStepEarly = true
            self.speak(presentation, circled: false)
            self.updateHUD(for: presentation)
        }
        defer {
            earlySpeechTask?.cancel()
            earlySpeechTask = nil
        }
        if step.needsVisibleControl || step.target != nil, isLaunchingApp(step.app) {
            await waitForApp(of: step)
        }
        // The screenshot the step was planned on, if it is still the screen; else a fresh one.
        var capture = capturesByObservation.first { $0.0 == presentation.observation.identifier }?.1
        if capture == nil || Date().timeIntervalSince(presentation.observation.capturedAt) > 1.5 {
            capture = try? await CaptureService.captureCursorDisplay()
        }
        guard let capture else {
            // No screen (a password field): still say the step; the tree can still tell when.
            speak(presentation, circled: false)
            updateHUD(for: presentation)
            return .shown(target: nil, source: "no screen")
        }
        var perception: ScreenPerception?
        var nativeRect: CGRect?
        var accessibilityFrame: CGRect?
        var source = "none"
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        if step.hasTarget {
            // 1. The accessibility tree (exact frames), retried briefly while a panel animates.
            if let query = step.target {
                for attempt in 0...Self.accessibilityRetries {
                    if attempt > 0 {
                        try? await Task.sleep(for: .seconds(Self.accessibilityRetrySeconds))
                    }
                    let snapshot =
                        attempt == 0
                        ? presentation.observation.snapshot
                        : await AccessibilityService.snapshotOfFrontmostApp()
                    let visibleArea = capture.screenSpace.accessibilityVisibleArea(
                        mainDisplayHeight: mainDisplayHeight)
                    var node =
                        snapshot?.isUsable == true
                        ? AccessibilityMatcher.bestMatch(
                            for: query, in: snapshot!, visibleArea: visibleArea) : nil
                    // The Dock is its own app: "click Chrome in the Dock".
                    if node == nil, step.app?.lowercased() == "dock" || attempt == 0,
                        let dock = await AccessibilityService.snapshotOfDock()
                    {
                        node = AccessibilityMatcher.bestMatch(
                            for: query, in: dock, visibleArea: visibleArea)
                    }
                    if let node {
                        accessibilityFrame = node.frame
                        nativeRect = capture.screenSpace.accessibilityRectToNativePixels(
                            node.frame, mainDisplayHeight: mainDisplayHeight)
                        source = "accessibility"
                        break
                    }
                    if snapshot?.isUsable != true { break }
                }
            }
            // 2. The planner's point, on the screen it planned from, snapped to a real element.
            if nativeRect == nil, presentation.pointIsFresh, let point = step.targetPointNorm1000 {
                perception = await PerceptionService.perceive(capture)
                nativeRect = Self.snappedRect(
                    norm1000: point, capture: capture, perception: perception)
                source = "planned point"
            }
            // 3. The control's name by OCR.
            if nativeRect == nil, let name = step.target?.name ?? step.label {
                if perception == nil { perception = await PerceptionService.perceive(capture) }
                let resolver = TargetResolver(
                    screenSpace: capture.screenSpace, marks: perception?.marks ?? [],
                    snapTargets: perception?.snapTargets ?? [],
                    cursorInNativePixels: capture.cursorInNativePixels)
                if let resolved = resolver.resolve(.text(name, near: nil, within: nil)),
                    !resolved.isLowConfidence
                {
                    nativeRect = resolved.rectInNativePixels
                    source = "text"
                }
            }
            // 4. One quick look by the fast model.
            if nativeRect == nil, let point = await locateWithModel(step: step, capture: capture) {
                if perception == nil { perception = await PerceptionService.perceive(capture) }
                nativeRect = Self.snappedRect(
                    norm1000: point, capture: capture, perception: perception)
                source = "model look"
            }
        }
        Self.log.notice(
            "🧭 walkthrough: step \(presentation.number) found by \(source, privacy: .public) in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
        )
        if step.hasTarget, nativeRect == nil, step.needsVisibleControl {
            return .missing
        }
        if accessibilityFrame == nil, let nativeRect {
            accessibilityFrame = capture.screenSpace.nativePixelsToAccessibilityRect(
                nativeRect, mainDisplayHeight: mainDisplayHeight)
        }
        draw(presentation, nativeRect: nativeRect, capture: capture, perception: perception)
        return .shown(target: accessibilityFrame, source: source)
    }

    /// Circles the control and says the step in the same moment (the circle first, so it is
    /// there when the words start).
    private func draw(
        _ presentation: GuidePresentation, nativeRect: CGRect?, capture: ScreenCaptureResult,
        perception: ScreenPerception?
    ) {
        guard let turnController else { return }
        stepCapture = capture
        var actions: [ScriptAction] = []
        if let nativeRect {
            let region = Self.region(for: nativeRect, in: capture.screenSpace)
            stepTargetRegion = region
            stepTargetRectInAppKitGlobal = Self.appKitGlobalRect(
                for: nativeRect, in: capture.screenSpace)
            actions.append(
                .draw(
                    DrawAction(
                        shape: .ellipse, target: region, from: nil, to: nil, anchor: nil,
                        role: presentation.step.kind == .observe ? "explain" : "focus",
                        label: "\(presentation.number)", life: "step",
                        identifier: "walk-step-\(presentation.number)",
                        group: "walk\(presentation.number)")))
        }
        earlySpeechTask?.cancel()
        if presentation.speaks, !spokeCurrentStepEarly {
            if !lastSpeechWasFiller { turnController.voiceOut.stop() }
            lastSpeechWasFiller = false
            actions.append(
                .speak(
                    SpeakAction(text: presentation.spokenText, group: "walk\(presentation.number)"))
            )
        }
        turnController.performLocalScript(
            actions, capture: capture, perception: perception,
            question: presentation.step.instruction)
        updateHUD(for: presentation)
        hud.show(
            onDisplay: capture.screenSpace.displayFrameInAppKitGlobal,
            avoiding: stepTargetRectInAppKitGlobal)
    }

    private func speak(_ presentation: GuidePresentation, circled: Bool) {
        guard presentation.speaks else { return }
        if !lastSpeechWasFiller { turnController?.voiceOut.stop() }
        lastSpeechWasFiller = false
        turnController?.voiceOut.speak(SpeakAction(text: presentation.spokenText))
    }

    private func updateHUD(for presentation: GuidePresentation) {
        hud.model.progressText =
            presentation.estimatedTotal.map {
                "Step \(presentation.number) of ~\(max($0, presentation.number))"
            }
            ?? "Step \(presentation.number)"
        hud.model.instruction = presentation.step.instruction
        hud.model.shortcutSymbols =
            presentation.step.shortcut.flatMap(KeyboardShortcut.init(parsing:))?.symbols
        hud.model.statusText = nil
        hud.model.canGoBack = presentation.number > 1
    }

    /// Waits (bounded) for the step's app to come to the front, e.g. while it launches.
    /// A real app that isn't in front yet (it may be launching from the Dock or Spotlight).
    /// System surfaces (Control Center, Spotlight, the menu bar) never come "to the front".
    private func isLaunchingApp(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        if frontmost.localizedCaseInsensitiveContains(name)
            || (!frontmost.isEmpty && name.localizedCaseInsensitiveContains(frontmost))
        {
            return false
        }
        let isRunningApp = NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular
                && ($0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame)
        }
        let isInstalledApp =
            FileManager.default.fileExists(atPath: "/Applications/\(name).app")
            || FileManager.default.fileExists(atPath: "/System/Applications/\(name).app")
        return isRunningApp || isInstalledApp
    }

    private func waitForApp(of step: WalkthroughStep) async {
        guard let appName = step.app, appName.lowercased() != "dock" else { return }
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < Self.longestAppWaitSeconds {
            let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if frontmost.localizedCaseInsensitiveContains(appName)
                || (!frontmost.isEmpty && appName.localizedCaseInsensitiveContains(frontmost))
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func locateWithModel(step: WalkthroughStep, capture: ScreenCaptureResult) async
        -> CGPoint?
    {
        guard let client = engineHost.client, let router = engineHost.router,
            let model = try? router.candidateModels(for: .fast, requiresVision: true).first
        else { return nil }
        let reply = await GroundingService.collectReply(
            from: await client.completeTurn(
                slot: ModelSlot.fast.rawValue, model: model,
                system: WalkthroughPrompts.locateSystemPrompt,
                prompt: WalkthroughPrompts.locatePrompt(
                    description: step.targetDescription, instruction: step.instruction),
                imageDataURLs: [
                    "data:image/jpeg;base64,\(capture.modelJPEGData.base64EncodedString())"
                ],
                maxTokens: 8192),
            timeoutSeconds: Self.locateTimeoutSeconds, client: client)
        return reply.flatMap(WalkthroughPrompts.locatedPoint(in:))
    }

    // MARK: - GuideDelegate: the rest

    func guideClearStep() {
        clearStepMarks()
    }

    private func clearStepMarks() {
        stepTargetRectInAppKitGlobal = nil
        turnController?.annotationController.clearStepMarks()
    }

    func guideSpeak(_ text: String) {
        lastSpeechWasFiller = false
        turnController?.voiceOut.speak(SpeakAction(text: text))
    }

    func guideFiller(_ text: String) {
        guard let turnController, !isAnsweringQuestion else { return }
        lastSpeechWasFiller = true
        turnController.voiceOut.speak(SpeakAction(text: text))
    }

    /// "It's right here": a ring on the waiting step's control.
    func guideNudge() {
        guard let turnController, !turnController.voiceOut.isSpeaking else { return }
        if let stepTargetRegion, stepTargetRectInAppKitGlobal != nil {
            turnController.performScriptActions([
                .speak(SpeakAction(text: "{a1}It's right here.")),
                .draw(
                    DrawAction(
                        shape: .ring, target: stepTargetRegion, from: nil, to: nil, anchor: "a1",
                        role: "focus", label: nil, life: "transient", identifier: nil, group: nil)),
            ])
        } else if let step = coordinator.currentStep {
            turnController.voiceOut.speak(
                SpeakAction(text: WalkthroughPrompts.spokenInstruction(for: step, isRepeat: true)))
        }
    }

    func guideAsk(question: String, options: [String]) {
        clearStepMarks()
        hud.model.statusText = "Your choice"
        hud.model.instruction = question
        questionPanel.show(
            AdaptiveDecision(question: question, options: options),
            onAnswer: { [weak self] option in self?.coordinator.choose(option) },
            onStop: { [weak self] in self?.end(saying: "Okay, stopping here.") })
        turnController?.voiceOut.stop()
        turnController?.voiceOut.speak(SpeakAction(text: question))
    }

    func guideHideQuestion() {
        questionPanel.hide()
    }

    func guidePaused(_ isPaused: Bool, appName: String?) {
        hud.model.statusText =
            isPaused ? "Paused · back to \(appName ?? "the app") to continue" : nil
        Self.log.notice("🧭 walkthrough: \(isPaused ? "paused" : "resumed", privacy: .public)")
    }

    func guideFinished(steps: [WalkthroughStep]) {
        let title = WalkthroughSession(goal: goal, appName: appName).title
        cleanUp()
        userData.saveHowTo(
            title: title, appName: appName, steps: steps, replacing: savedHowToIdentifier)
        userData.recordWalkthroughCompleted(inApp: appName)
        recap.show(
            title: title, appName: appName, steps: steps, wasSaved: !steps.isEmpty, onDisplay: nil)
        let closing =
            userData.modes.isKidsModeOn ? "You did it! Great job." : "That's it, you're done."
        turnController?.voiceOut.speak(SpeakAction(text: closing))
        Self.log.notice("🧭 walkthrough: finished \(steps.count) steps")
        savedHowToIdentifier = nil
    }

    func guideEnded() {
        cleanUp()
        Self.log.notice("🧭 walkthrough: ended")
    }

    /// Content-light: roles, timings, sources; never the user's words or the screen's text.
    func guideTrace(_ event: GuideTraceEvent) {
        switch event {
        case .modelCall(let role, let milliseconds, let succeeded):
            Self.log.notice(
                "🧭 \(role.rawValue, privacy: .public) \(milliseconds) ms\(succeeded ? "" : " (unusable)", privacy: .public)"
            )
        case .presented(let number, let source, let since):
            Self.log.notice(
                "🧭 step \(number) shown via \(source, privacy: .public)\(since.map { ", \($0) ms after the user acted" } ?? "", privacy: .public)"
            )
        case .stepDone(let number, let how):
            Self.log.notice("🧭 step \(number) done (\(how.prefix(40), privacy: .private))")
        case .candidate(let verdict):
            Self.log.notice("🧭 prediction \(verdict, privacy: .public)")
        case .asked(_, let options):
            Self.log.notice("🧭 asked the user (\(options.count) options)")
        case .recovery(let reason):
            Self.log.notice("🧭 recovery: \(reason, privacy: .private)")
        case .note(let text):
            Self.log.notice("🧭 \(text, privacy: .public)")
        case .unusableReply(let role, let excerpt):
            // The reply can quote the screen: Xcode console only, never the unified log.
            Self.log.notice("🧭 \(role.rawValue, privacy: .public) reply unusable (see console)")
            print("🧭 unusable \(role.rawValue) reply: \(excerpt)")
        }
    }

    // MARK: - Watching the user (listen-only, only during a walkthrough)

    private func startWatchingInput() {
        stopWatchingInput()
        mouseDownLocation = nil
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            let location = NSEvent.mouseLocation
            let type = event.type
            let key = type == .keyDown ? Self.keyAndModifiers(from: event) : nil
            MainActor.assumeIsolated {
                self?.handleInput(type: type, location: location, key: key)
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observeFrontmostApp()
                self?.coordinator.handle(.appSwitched)
            }
        }
        observeFrontmostApp()
    }

    private func stopWatchingInput() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        changeObserver?.stop()
        changeObserver = nil
        observedProcessIdentifier = nil
    }

    /// Accessibility notifications from the app in front (re-attached when the user switches).
    private func observeFrontmostApp() {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier != Bundle.main.bundleIdentifier,
            application.processIdentifier != observedProcessIdentifier
        else { return }
        changeObserver?.stop()
        observedProcessIdentifier = application.processIdentifier
        changeObserver = AccessibilityService.ChangeObserver(
            processIdentifier: application.processIdentifier
        ) { [weak self] in
            self?.coordinator.handle(.screenMayHaveChanged)
        }
    }

    private func handleInput(
        type: NSEvent.EventType, location: CGPoint,
        key: (key: String, modifiers: Set<KeyboardShortcut.Modifier>)?
    ) {
        guard isActive else { return }
        switch type {
        case .leftMouseDown:
            mouseDownLocation = location
        case .leftMouseUp:
            let onTarget =
                stepTargetRectInAppKitGlobal?.insetBy(dx: -30, dy: -30).contains(
                    mouseDownLocation ?? location) ?? false
            mouseDownLocation = nil
            // Speech isn't cut off mid-word; the next step replaces it.
            coordinator.handle(.click(onTarget: onTarget))
        case .keyDown:
            guard let key else { return }
            let commandLike = key.modifiers.contains(.command) || key.modifiers.contains(.control)
            switch key.key {
            case "return" where !commandLike: coordinator.handle(.returnKey)
            case "tab" where !commandLike: coordinator.handle(.tabKey)
            case "escape": coordinator.handle(.escapeKey)
            default:
                if commandLike || key.key.count > 1 {
                    coordinator.handle(.shortcut(key: key.key, modifiers: key.modifiers))
                } else {
                    coordinator.handle(.typed)
                }
            }
        default:
            break
        }
    }

    private static func keyAndModifiers(from event: NSEvent)
        -> (key: String, modifiers: Set<KeyboardShortcut.Modifier>)?
    {
        let namedKeys: [UInt16: String] = [
            36: "return", 76: "return", 48: "tab", 49: "space", 53: "escape", 51: "delete",
            123: "left", 124: "right", 125: "down", 126: "up",
        ]
        let key = namedKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !key.isEmpty else { return nil }
        var modifiers: Set<KeyboardShortcut.Modifier> = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // Typing a space or deleting is typing, not a shortcut.
        if modifiers.isSubset(of: [.shift]), key == "space" || key == "delete" {
            return (" ", modifiers)
        }
        return (key, modifiers)
    }

    // MARK: - Geometry

    private static func snappedRect(
        norm1000 point: CGPoint, capture: ScreenCaptureResult, perception: ScreenPerception?
    ) -> CGRect? {
        let resolver = TargetResolver(
            screenSpace: capture.screenSpace, marks: perception?.marks ?? [],
            snapTargets: perception?.snapTargets ?? [],
            cursorInNativePixels: capture.cursorInNativePixels)
        return resolver.resolve(.pixel(x: point.x, y: point.y, space: "norm1000"))?
            .rectInNativePixels
    }

    static func region(for nativeRect: CGRect, in space: ScreenSpace) -> TargetDescriptor {
        .region(
            NormalizedRect(
                x: nativeRect.minX / space.nativePixelSize.width,
                y: nativeRect.minY / space.nativePixelSize.height,
                width: max(nativeRect.width, 1) / space.nativePixelSize.width,
                height: max(nativeRect.height, 1) / space.nativePixelSize.height), space: nil)
    }

    static func appKitGlobalRect(for nativeRect: CGRect, in space: ScreenSpace) -> CGRect {
        let display = space.nativePixelRectToDisplayPoints(nativeRect)
        let frame = space.displayFrameInAppKitGlobal
        return CGRect(
            x: frame.minX + display.minX, y: frame.maxY - display.maxY, width: display.width,
            height: display.height)
    }
}

extension String {
    /// "Step 3 of 7" → "step 3 of 7", for the middle of a sentence.
    var lowercasedFirstLetter: String {
        prefix(1).lowercased() + dropFirst()
    }
}
