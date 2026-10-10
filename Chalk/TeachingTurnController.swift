//
//  TeachingTurnController.swift
//  Chalk
//
//  One learner turn, end to end (§7.6, slice S04): key-down → screenshot + prewarm while the
//  learner talks → transcript → router picks slot and model (§7.4) → tutor-engine streams the
//  Teaching Script → each `speak` line is spoken as soon as it completes, and drawing actions go
//  to the AnnotationController, which draws them when the spoken anchor word arrives (S06).
//
//  Barge-in (§7.6, D45): pressing the key while Chalk is talking stops speech at the next word
//  and aborts the running turn; the new question then continues the same session, so the
//  conversation is kept.
//
//  Guided walkthroughs (§4.2.6, D74): a task request ("guide me how to…") becomes one plan turn
//  whose `step` lines go to the WalkthroughController, which runs them locally; while a
//  walkthrough runs, short
//  utterances are commands and anything else is a question answered on the same session.
//  Every turn carries the user's memory and modes (§4.3).
//

import AppKit
import ChalkCore
import Foundation
import os

@MainActor
final class TeachingTurnController {
    enum State {
        case thinking, speaking, idle
    }

    /// Timestamps for the §11.3 latency budget; logged as one line per turn.
    private struct TurnTimeline {
        var keyDown: Date?
        var keyUp: Date?
        var transcriptFinal: Date?
        var requestSent: Date?
        var firstText: Date?
        var firstSpeakLine: Date?
        var firstAnswerWord: Date?
        var acknowledgementWord: Date?
        var slot: ModelSlot?
        var model: String?
        var outcome = "?"
        var isFinished = false
    }

    private enum StreamOutcome {
        case completed
        case cancelled
        case failed(EngineError)
    }

    /// What a turn is for (§4.2.6): a normal answer, or one of the walkthrough's model turns.
    enum TurnPurpose {
        case answer
        /// The plan (or a re-plan, which continues the walkthrough's session) (D74).
        case walkthroughPlan(context: String, token: Int, continuesSession: Bool)
        case walkthroughQuestion(context: String, token: Int)

        /// The walkthrough controller's token for a plan turn.
        var walkthroughToken: Int? {
            if case .walkthroughPlan(_, let token, _) = self { return token }
            return nil
        }
    }

    /// A follow-up within this window continues the same session (and may use the fast slot).
    static let sessionReuseWindowSeconds: TimeInterval = 300
    /// D43: if no answer has started speaking by then, say a short acknowledgement.
    static let acknowledgementDelayMilliseconds = 700
    static let acknowledgementDelayWithFillerMilliseconds = 3500
    /// The question-aware filler was spoken: it was the acknowledgement.
    private var hasSpokenFillerThisTurn = false
    /// One opener per turn (D72): a fixed "one moment" and then a filler and then the answer
    /// sounded like Chalk starting three times.
    private var hasSpokenAcknowledgementThisTurn = false
    private static let acknowledgementPhrases = ["Let me look.", "One moment.", "Okay, let's see."]
    private static let latencyLog = Logger(subsystem: "com.chalk.app", category: "latency")
    private static let dispatchLog = Logger(subsystem: "com.chalk.app", category: "dispatch")
    private static let signposter = OSSignposter(subsystem: "com.chalk.app", category: "turn")

    let voiceOut = VoiceOut()
    let annotationController = AnnotationController()
    let userData: UserDataStore
    let walkthroughController: WalkthroughController
    var onStateChange: ((State) -> Void)?

    private let engineHost: TutorEngineHost
    /// The app the user was in when they pressed the talk key (§4.3 memory, §4.2.6 plans).
    private var frontmostAppName: String?
    /// The running turn, so steps in an ordinary answer can start a walkthrough (D69).
    private var turnSerial = 0
    private var currentTurnPurpose: TurnPurpose = .answer
    private var currentTurnTranscript = ""
    /// The token of a walkthrough adopted during turn `turnSerial`.
    private var adoptedWalkthrough: (turnSerial: Int, token: Int)?
    private var sessionIdentifier: String?
    /// The engine run the session lives in (TutorEngineHost.engineGeneration).
    private var sessionEngineGeneration: Int?
    private var lastTurnFinishedAt: Date?
    private var currentTurnTask: Task<Void, Never>?
    private var pendingCaptureTask: Task<ScreenCaptureResult?, Never>?
    private var pendingPerceptionTask: Task<ScreenPerception?, Never>?
    private var captureWasBlockedBySecureInput = false

    /// What the user drew with ⌃⌥ held this turn (§4.2.5): kept only for the turn (§10.1).
    private var learnerDrawing: (stroke: LearnerStroke, strokes: [[CGPoint]], displayFrame: CGRect)?
    /// The lassoed region in display points (top-left) and its display, for the chooser.
    var learnerDrawingRegion: (region: CGRect, displayFrame: CGRect)? {
        learnerDrawing.map { ($0.stroke.region, $0.displayFrame) }
    }

    /// The screen this turn is about, kept for drawing (S06) and target resolution (S08).
    private(set) var currentScreen: (capture: ScreenCaptureResult, perception: ScreenPerception?)?

    /// How the model points (D48): `coordinates` (default) sends the clean screenshot and the
    /// model answers with text labels or 0–1000 points, which the app snaps to a candidate;
    /// `marks` sends the set-of-marks image plus the marks list (§6.2 c). Measured on real screens
    /// with Flash Lite: coordinates + zoom + snap 89%, marks 63% (D40).
    enum PointingMode: String {
        case coordinates, marks
    }
    static let pointingModeDefaultsKey = "ChalkPointingMode"
    static var pointingMode: PointingMode {
        PointingMode(rawValue: UserDefaults.standard.string(forKey: pointingModeDefaultsKey) ?? "")
            ?? .coordinates
    }
    private var acknowledgementTask: Task<Void, Never>?
    /// D63: a question-aware line (then one progress line) while the main model thinks.
    private var thinkingFillerTask: Task<Void, Never>?
    /// The fast path's whole system prompt: each quick call's own prompt says the format.
    static let fastPathSystemPrompt =
        "You are Chalk, a calm voice assistant on a Mac. Reply only with the JSON lines asked for, nothing else."
    /// How long the fast slot gets to write a filler before it's pointless.
    static let thinkingFillerTimeoutSeconds = 6.0
    private var hasQueuedAnswerSpeechThisTurn = false
    private var timeline = TurnTimeline()
    private var signpostState: OSSignpostIntervalState?

    var isBusy: Bool { currentTurnTask != nil || voiceOut.isSpeaking }

    init(engineHost: TutorEngineHost, userData: UserDataStore) {
        self.engineHost = engineHost
        self.userData = userData
        walkthroughController = WalkthroughController(engineHost: engineHost, userData: userData)
        annotationController.groundingService = GroundingService(engineHost: engineHost)
        // §5.10 low-confidence copy; S09's lasso is how the learner answers it.
        annotationController.onAskLearnerToCircle = { [weak self] in
            // In a walkthrough the step hints help instead (D74).
            guard self?.walkthroughController.isActive == false else { return }
            self?.voiceOut.speak(
                SpeakAction(text: "I'm not sure exactly where. Can you circle it?"))
        }
        voiceOut.onUtteranceStartedSpeaking = { [weak self] isAcknowledgement in
            guard let self else { return }
            if isAcknowledgement {
                if self.timeline.acknowledgementWord == nil {
                    self.timeline.acknowledgementWord = Date()
                }
            } else if self.timeline.firstAnswerWord == nil {
                self.timeline.firstAnswerWord = Date()
                self.logTimelineIfComplete()
            }
            self.onStateChange?(.speaking)
        }
        voiceOut.onFinishedSpeaking = { [weak self] in
            guard let self, self.currentTurnTask == nil else { return }
            self.annotationController.turnEnded()
            self.onStateChange?(.idle)
        }
        voiceOut.onRangeWillBeSpoken = {
            [weak self] utteranceNumber, currentWordRange, callbackTime in
            self?.annotationController.rangeWillBeSpoken(
                utteranceIdentifier: utteranceNumber, range: currentWordRange,
                anchorReachedAt: callbackTime)
        }
        voiceOut.onUtteranceFinished = { [weak self] utteranceNumber in
            self?.annotationController.utteranceFinished(utteranceIdentifier: utteranceNumber)
        }
        // D72/D73: the next sentence waits for the pen to finish the line this one revealed.
        voiceOut.shouldHoldNextSentence = { [weak self] in
            self?.annotationController.whiteboard.hasPendingWriting ?? false
        }
        walkthroughController.turnController = self
    }

    // MARK: - Key events

    /// Talk key pressed: barge-in, prewarm, and start the screenshot while the learner speaks.
    func learnerStartedTalking() {
        if walkthroughController.isPlanStreaming {
            // Keep the start turn streaming: step 1 is on its way. A question still stops it
            // (ask).
            voiceOut.stop()
            acknowledgementTask?.cancel()
            thinkingFillerTask?.cancel()
            annotationController.clearAll(fast: true)
        } else {
            stopSpeakingAndDrawing()
        }
        walkthroughController.userStartedTalking()
        learnerDrawing = nil
        timeline = TurnTimeline(keyDown: Date())
        signpostState = Self.signposter.beginInterval("turn")
        engineHost.prewarmIfNeeded()
        frontmostAppName = Self.currentFrontmostAppName()
        beginScreenCapture()
    }

    /// The user's app, not Chalk (its panels never activate it).
    private static func currentFrontmostAppName() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        return application.localizedName
    }

    /// D43 / §7.6 latency trick: capture and perception start at key-down, not key-up, so they
    /// overlap the user speaking. A re-plan (§4.2.6 step 6) starts one without a key press.
    private func beginScreenCapture() {
        Self.dispatchLog.notice("Capture requested for user-started turn")
        captureWasBlockedBySecureInput = false
        currentScreen = nil
        let captureTask = Task { [weak self] () -> ScreenCaptureResult? in
            do {
                return try await CaptureService.captureCursorDisplay()
            } catch CaptureServiceError.secureInputActive {
                Self.dispatchLog.notice("Capture blocked: secure input active")
                self?.captureWasBlockedBySecureInput = true
                return nil
            } catch {
                Self.dispatchLog.error(
                    "Capture failed: proceeding without screenshot (details in Xcode console)")
                print("⚠️ Turn: screenshot failed, answering without the screen: \(error)")
                return nil
            }
        }
        pendingCaptureTask = captureTask
        pendingPerceptionTask = Task {
            guard let capture = await captureTask.value else { return nil }
            let perception = await PerceptionService.perceive(capture)
            if let perception {
                Self.dispatchLog.notice(
                    "Perception complete: candidates=\(perception.candidateCount) marks=\(perception.marks.count) durationMs=\(perception.milliseconds)"
                )
                print(
                    "👁️ Perception: \(perception.marks.count) marks, \(perception.snapTargets.count) snap targets "
                        + "from \(perception.candidateCount) candidates in \(perception.milliseconds) ms"
                )
            }
            return perception
        }
    }

    /// Esc and the talk key (§4.2.2 rule 3): stop talking, abort the running turn, clear the
    /// marks within 150 ms.
    func stopSpeakingAndDrawing() {
        voiceOut.stop()
        acknowledgementTask?.cancel()
        thinkingFillerTask?.cancel()
        if let runningTurn = currentTurnTask {
            runningTurn.cancel()
            currentTurnTask = nil
            if let sessionIdentifier, let client = engineHost.client {
                Task { await client.abort(sessionIdentifier: sessionIdentifier) }
            }
        }
        annotationController.clearAll(fast: true)
    }

    /// The learner let go of ⌃⌥ after drawing. Returns true when it was a real gesture (so a
    /// silent release can mean "explain this region").
    @discardableResult
    func learnerDrew(strokes: [[CGPoint]], displayFrame: CGRect) -> Bool {
        guard let stroke = LassoClassifier.classify(strokes) else { return false }
        // The trail leaves with the panel on release (owner, hand test 4); the model still gets
        // the strokes drawn on its screenshot.
        learnerDrawing = (stroke, strokes, displayFrame)
        print("✍️ Learner drew a \(stroke.kind) around \(stroke.region.integral)")
        return true
    }

    var hasLearnerDrawing: Bool { learnerDrawing != nil }

    func learnerReleasedKey() {
        timeline.keyUp = Date()
    }

    /// The final transcript arrived: a walkthrough command, a question, or a new request.
    func ask(_ transcript: String) {
        if WalkthroughCommand.parse(transcript) == .stop, walkthroughController.isActive {
            walkthroughController.end(saying: "Okay, stopping here.")
            return
        }
        if walkthroughController.isActive, let command = WalkthroughCommand.parse(transcript),
            walkthroughController.handle(command)
        {
            return
        }
        if walkthroughController.handleAdaptiveAnswer(transcript) { return }
        // Content-free diagnostics: expose intent dispatch without retaining the user's words.
        Self.dispatchLog.notice(
            "Turn dispatch: walkthroughRequested=\(WalkthroughIntent.isWalkthroughRequest(transcript)) activeWalkthrough=\(self.walkthroughController.isActive) workedSolution=\(QuestionContext.isWorkedSolution(transcript)) geometryHint=\(FigureHint.forQuestion(transcript) != nil)"
        )
        if walkthroughController.isActive {
            if let command = WalkthroughCommand.parse(transcript),
                walkthroughController.handle(command)
            {
                return
            }
            if WalkthroughIntent.isWalkthroughRequest(transcript) {
                // A new task replaces the one running.
                walkthroughController.end(saying: nil)
            } else if let question = walkthroughController.questionStarted() {
                // §4.2.6 step 8: a question mid-walkthrough, answered on the same session.
                startTurn(
                    transcript: transcript,
                    purpose: .walkthroughQuestion(context: question.context, token: question.token))
                return
            }
        }
        if WalkthroughIntent.isWalkthroughRequest(transcript) {
            if currentTurnTask != nil { stopSpeakingAndDrawing() }
            walkthroughController.start(
                goal: transcript, appName: frontmostAppName, keyDownCapture: pendingCaptureTask)
            return
        }
        startTurn(transcript: transcript, purpose: .answer)
    }

    /// A walkthrough plan or re-plan turn (D74). A re-plan looks at a fresh screenshot and
    /// continues the walkthrough's session, so the model remembers the task.
    func startWalkthroughPlanTurn(
        context: String, token: Int, continuesSession: Bool, transcript: String,
        freshCapture: Bool
    ) {
        if freshCapture {
            timeline = TurnTimeline(keyDown: Date())
            beginScreenCapture()
        }
        startTurn(
            transcript: transcript,
            purpose: .walkthroughPlan(
                context: context, token: token, continuesSession: continuesSession))
    }

    private func startTurn(transcript: String, purpose: TurnPurpose) {
        // One answer at a time: a turn still running is stopped first (two overlapping turns
        // interleaved their speech and board steps, owner's report, D65).
        if currentTurnTask != nil { stopSpeakingAndDrawing() }
        timeline.transcriptFinal = Date()
        currentTurnTask = Task { [weak self] in
            let serial = await self?.runTurn(transcript: transcript, purpose: purpose)
            guard let self else { return }
            let wasCancelled = Task.isCancelled
            if let adopted = self.adoptedWalkthrough, adopted.turnSerial == serial {
                self.adoptedWalkthrough = nil
                self.walkthroughController.planTurnEnded(
                    token: adopted.token, wasCancelled: wasCancelled)
            }
            switch purpose {
            case .walkthroughPlan(_, let token, _):
                self.walkthroughController.planTurnEnded(token: token, wasCancelled: wasCancelled)
            case .walkthroughQuestion(_, let token):
                self.walkthroughController.questionTurnEnded(
                    token: token, wasCancelled: wasCancelled)
            case .answer:
                break
            }
            guard !wasCancelled else { return }
            self.currentTurnTask = nil
            if !self.voiceOut.isSpeaking {
                self.annotationController.turnEnded()
                self.onStateChange?(.idle)
            }
        }
    }

    /// Stop: a walkthrough turn still running is cancelled, so it can't speak or draw after the
    /// walkthrough ended (D73).
    func cancelWalkthroughTurnIfRunning() {
        guard currentTurnPurpose.walkthroughToken != nil, let runningTurn = currentTurnTask
        else { return }
        runningTurn.cancel()
        currentTurnTask = nil
        acknowledgementTask?.cancel()
        thinkingFillerTask?.cancel()
        if let sessionIdentifier, let client = engineHost.client {
            Task { await client.abort(sessionIdentifier: sessionIdentifier) }
        }
    }

    /// The lasso chooser picked an action (§4.2.5, §4.3): ask about the circled region.
    func askAboutRegion(_ action: RegionAction) {
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let languageName =
            Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? "English"
        ask(action.prompt(targetLanguage: languageName))
    }

    // MARK: - Local scripts (walkthrough steps)

    /// Runs actions written by the app, not the model (a walkthrough step, §4.2.6 step 3), on
    /// the given screen: speech with anchors and drawings, through the same timing path.
    func performLocalScript(
        _ actions: [ScriptAction], capture: ScreenCaptureResult?, perception: ScreenPerception?,
        question: String
    ) {
        annotationController.beginTurn(capture: capture, perception: perception, question: question)
        performScriptActions(actions)
    }

    /// The same, on the screen already set up (the hint ring on a waiting step).
    func performScriptActions(_ actions: [ScriptAction]) {
        handle(actions.map { ScriptEvent.action($0) }, fromModel: false)
        annotationController.scriptFinished()
    }

    // MARK: - Turn

    /// Returns the turn's serial (for a walkthrough adopted from its steps, D69).
    @discardableResult
    private func runTurn(transcript: String, purpose: TurnPurpose) async -> Int {
        turnSerial += 1
        let serial = turnSerial
        currentTurnPurpose = purpose
        currentTurnTranscript = transcript
        await runTurnBody(transcript: transcript, purpose: purpose)
        return serial
    }

    private func runTurnBody(transcript: String, purpose: TurnPurpose) async {
        onStateChange?(.thinking)
        hasQueuedAnswerSpeechThisTurn = false
        hasSpokenFillerThisTurn = false
        hasSpokenAcknowledgementThisTurn = false
        voiceOut.speechRate =
            userData.modes.isKidsModeOn ? AssistantModes.kidsSpeechRate : VoiceOut.teachingRate
        if case .answer = purpose { userData.recordQuestion(inApp: frontmostAppName) }
        if case .walkthroughPlan(_, _, false) = purpose {
            userData.recordQuestion(inApp: frontmostAppName)
        }
        guard let client = engineHost.client, let router = engineHost.router else {
            speakFailure(
                "I can't reach my teaching engine. Build it with bun run build colon bin, then restart me."
            )
            return
        }
        let screenshot = await pendingCaptureTask?.value
        if captureWasBlockedBySecureInput {
            // §10.2: never look while a password field is focused; say so and answer anyway.
            voiceOut.speak(
                SpeakAction(text: "A password field is focused, so I won't look at your screen."))
        }
        // A session only continues in the engine run that holds it: after a profile switch the
        // old session is gone, and continuing it failed every Cline turn (owner's report).
        let isSessionAlive =
            sessionIdentifier != nil && sessionEngineGeneration == engineHost.engineGeneration
        let isRecent =
            lastTurnFinishedAt.map {
                Date().timeIntervalSince($0) < Self.sessionReuseWindowSeconds
            } ?? false
        // One session per walkthrough (owner, D73): the start opens it, and every check and
        // question continues it however long the user spent on a step, so the model remembers
        // what it saw, said and circled. Fresh sessions per check lost that and repeated
        // themselves ("Google Flights is open" again and again).
        let isFollowUp: Bool
        switch purpose {
        case .walkthroughQuestion: isFollowUp = isSessionAlive
        case .walkthroughPlan(_, _, let continuesSession):
            isFollowUp = continuesSession && isSessionAlive
        case .answer: isFollowUp = isSessionAlive && isRecent
        }
        // D70/D72: the start plans on the teaching slot; checks run after every user action,
        // so they use the fast slot (Sonnet's 5–7 s per check made every step feel stuck).
        let slot: ModelSlot
        switch purpose {
        // D77: plans on the teaching slot (Sonnet 5.5: the better path), the filler covering the
        // wait; every step then gets a fast live look (Haiku 5.5) at the real screen.
        case .walkthroughPlan: slot = .teaching
        case .answer, .walkthroughQuestion:
            slot = ModelRouter.slot(forTranscript: transcript, isFollowUp: isFollowUp)
        }
        let candidateModels: [String]
        do {
            candidateModels = try router.candidateModels(
                for: slot, requiresVision: screenshot != nil)
        } catch {
            print("⚠️ Turn: routing failed: \(error)")
            Self.dispatchLog.error("Model routing failed: no compatible candidate")
            speakFailure("None of my models can look at your screen right now.")
            return
        }
        if screenshot == nil {
            annotationController.beginTurn(capture: nil, perception: nil, question: transcript)
        }
        var imageDataURLs: [String] = []
        var prompt = transcript
        if let screenshot {
            let perception = await pendingPerceptionTask?.value
            currentScreen = (screenshot, perception)
            annotationController.beginTurn(
                capture: screenshot, perception: perception, question: transcript)
            var imageData = screenshot.modelJPEGData
            let usesMarks = Self.pointingMode == .marks && perception != nil
            let drawingOnThisScreen = learnerDrawing.flatMap {
                $0.displayFrame == screenshot.screenSpace.displayFrameInAppKitGlobal ? $0 : nil
            }
            if usesMarks || drawingOnThisScreen != nil,
                let modelImage = MarksImageRenderer.modelImage(
                    from: screenshot.nativeImage, screenSpace: screenshot.screenSpace,
                    marks: usesMarks ? perception?.marks : nil),
                let jpeg = MarksImageRenderer.jpegData(
                    drawingOnThisScreen.flatMap {
                        LearnerDrawingImages.drawing(
                            $0.strokes, region: $0.stroke.region, onto: modelImage,
                            screenSpace: screenshot.screenSpace)
                    } ?? modelImage)
            {
                imageData = jpeg
            }
            if usesMarks, let perception {
                // §6.2 c: tags on the image plus the compact list, so the model can say {"mark": n}.
                let marksList = MarkSelection.promptList(
                    for: perception.marks, screenSpace: screenshot.screenSpace)
                prompt =
                    "<context>\nMarks on screen (id, kind, text, centre in image pixels):\n\(marksList)\n</context>\n\n\(transcript)"
            }
            imageDataURLs = ["data:image/jpeg;base64,\(imageData.base64EncodedString())"]
            // §4.2.5: the learner's strokes are drawn onto the screenshot (violet) and the region
            // goes along as a native-resolution crop, so small text in it is readable.
            if let drawingOnThisScreen,
                let cropJPEG = LearnerDrawingImages.regionCrop(
                    drawingOnThisScreen.stroke.region, from: screenshot.nativeImage,
                    screenSpace: screenshot.screenSpace)
            {
                imageDataURLs.append("data:image/jpeg;base64,\(cropJPEG.base64EncodedString())")
                prompt =
                    LearnerDrawingImages.contextLine(
                        for: drawingOnThisScreen.stroke, screenSpace: screenshot.screenSpace)
                    + "\n\n" + prompt
            } else if let cursor = screenshot.cursorInNativePixels {
                // D62: say where the pointer is ("this question" on a page of several), and for a
                // worked solution send the area around it at full resolution, so small maths is
                // read exactly.
                prompt =
                    QuestionContext.pointerLine(
                        cursorInNativePixels: cursor, screenSpace: screenshot.screenSpace)
                    + "\n\n" + prompt
                if QuestionContext.isWorkedSolution(transcript),
                    let crop = screenshot.nativeImage.cropping(
                        to: QuestionContext.cropAroundPointer(
                            cursorInNativePixels: cursor, screenSpace: screenshot.screenSpace)),
                    let cropJPEG = MarksImageRenderer.jpegData(crop)
                {
                    imageDataURLs.append("data:image/jpeg;base64,\(cropJPEG.base64EncodedString())")
                }
            }
            learnerDrawing = nil
        }
        if case .answer = purpose {
            if QuestionContext.isWorkedSolution(transcript) {
                prompt = QuestionContext.workedSolutionLine + "\n\n" + prompt
            }
            // A shape request gets a deterministic nudge toward the geometry figure (D60).
            if let figureHint = FigureHint.forQuestion(transcript) {
                prompt = figureHint.contextLine + "\n\n" + prompt
            }
        }
        // §4.3: memory, modes and the walkthrough's state go first, so the question stays last.
        var contextBlocks: [String] = []
        if let memoryBlock = userData.memory.promptBlock() { contextBlocks.append(memoryBlock) }
        if let modesBlock = userData.modes.contextBlock { contextBlocks.append(modesBlock) }
        switch purpose {
        case .answer: break
        case .walkthroughPlan(let context, _, _), .walkthroughQuestion(let context, _):
            contextBlocks.append(context)
        }
        if !contextBlocks.isEmpty {
            prompt = contextBlocks.joined(separator: "\n\n") + "\n\n" + prompt
        }
        // With a filler coming (teaching or deep slot), it is the acknowledgement; the fixed
        // "let me look" only covers a filler that hasn't arrived after 2.5 s. Three openers in a
        // row ("let me look", the filler, "sure…") sounded broken (owner's report, D65). A
        // re-plan already said "let me take another look".
        if case .walkthroughPlan(_, _, true) = purpose {
            // Said by the walkthrough.
        } else if slot != .fast {
            scheduleAcknowledgement(
                afterMilliseconds: Self.acknowledgementDelayWithFillerMilliseconds)
            startThinkingFiller(transcript: transcript, screen: currentScreen)
        } else {
            scheduleAcknowledgement(afterMilliseconds: Self.acknowledgementDelayMilliseconds)
        }

        // §7.4 rule 5: the primary, then one fallback if the first fails before speaking.
        // Attempts: continue the session (follow-ups), then a fresh session on the same model if
        // that fails before speaking, then the slot's fallback model (§7.4 rule 5).
        var attempts: [(model: String, continuesSession: Bool)] = candidateModels.prefix(2).map {
            ($0, false)
        }
        if isFollowUp, let primary = candidateModels.first {
            attempts.insert((primary, true), at: 0)
        }
        for (attemptIndex, attempt) in attempts.enumerated() {
            let model = attempt.model
            Self.dispatchLog.notice(
                "Model request: slot=\(slot.rawValue, privacy: .public) model=\(model, privacy: .public) attempt=\(attemptIndex + 1) continuing=\(attempt.continuesSession)"
            )
            timeline.slot = slot
            timeline.model = model
            timeline.requestSent = Date()
            let stream: AsyncStream<EngineEvent>
            if attempt.continuesSession, let sessionIdentifier {
                stream = await client.sendTurn(
                    sessionIdentifier: sessionIdentifier, prompt: prompt, model: model,
                    imageDataURLs: imageDataURLs)
            } else {
                stream = await client.startTurn(
                    EngineTurnRequest(
                        slot: slot.rawValue, model: model, prompt: prompt,
                        imageDataURLs: imageDataURLs))
            }
            switch await consume(stream, client: client) {
            case .completed:
                timeline.outcome = "completed"
                finishTurn()
                return
            case .cancelled:
                timeline.outcome = "interrupted"
                logTimeline()
                return
            case .failed(let engineError):
                Self.dispatchLog.error(
                    "Model failed: kind=\(engineError.kind, privacy: .public) retryable=\(engineError.isRetryable) model=\(model, privacy: .public)"
                )
                print("⚠️ Turn: \(model) failed: \(engineError.kind) \(engineError.message)")
                let isLastAttempt = attemptIndex == attempts.count - 1
                // A failed continuation always gets a fresh session; another model only for
                // retryable errors.
                let canRetry =
                    !hasQueuedAnswerSpeechThisTurn && !isLastAttempt
                    && (attempt.continuesSession || engineError.isRetryable)
                if canRetry { continue }
                timeline.outcome = "failed: \(engineError.kind)"
                finishTurn()
                speakFailure(Self.spokenMessage(for: engineError))
                return
            }
        }
    }

    private func consume(_ stream: AsyncStream<EngineEvent>, client: TutorEngineClient) async
        -> StreamOutcome
    {
        // Walkthrough turns never speak prose: a stray thought ("I'll draw an ellipse…") was read
        // aloud (D73).
        var parser = StreamingScriptParser(
            speaksPlainText: currentTurnPurpose.walkthroughToken == nil)
        for await event in stream {
            guard !Task.isCancelled else { return .cancelled }
            switch event {
            case .session(let newSessionIdentifier, _):
                Self.dispatchLog.notice("Model session ready")
                sessionIdentifier = newSessionIdentifier
                sessionEngineGeneration = engineHost.engineGeneration
            case .text(let delta):
                if case .walkthroughPlan(_, let token, _) = currentTurnPurpose,
                    token != walkthroughController.planToken
                {
                    continue
                }
                if Task.isCancelled { return .cancelled }
                if timeline.firstText == nil {
                    Self.dispatchLog.notice("First model text received; parsing script")
                    timeline.firstText = Date()
                }
                handle(parser.feed(delta))
            case .usage:
                // Credit usage is never shown or logged (owner, D66).
                break
            case .toolCall(let callIdentifier, let name, _):
                // Flashcards and walkthrough steps arrive in S12/S13. Answer so the turn can't hang.
                print("🧰 Turn: tool \(name) is not available yet")
                await client.sendToolResult(
                    callIdentifier: callIdentifier,
                    result: .object(["ok": .bool(false), "error": .string("not available yet")]))
            case .done(let status):
                Self.dispatchLog.notice("Model stream ended: \(status, privacy: .public)")
                handle(parser.finish())
                annotationController.scriptFinished()
                return status == "aborted" ? .cancelled : .completed
            case .error(let engineError):
                handle(parser.finish())
                annotationController.scriptFinished()
                return .failed(engineError)
            case .pong:
                break
            }
        }
        return Task.isCancelled
            ? .cancelled
            : .failed(
                EngineError(
                    kind: "internal", isRetryable: true, message: "the answer stream ended early"))
    }

    /// `fromModel` is false for the app's own scripts (a walkthrough step's speech and circle).
    private func handle(_ scriptEvents: [ScriptEvent], fromModel: Bool = true) {
        for scriptEvent in scriptEvents {
            if fromModel && Task.isCancelled { break }
            switch scriptEvent {
            case .action(.speak(let speakAction)):
                Self.dispatchLog.notice("Speech queued: characters=\(speakAction.text.count)")
                if timeline.firstSpeakLine == nil { timeline.firstSpeakLine = Date() }
                hasQueuedAnswerSpeechThisTurn = true
                acknowledgementTask?.cancel()
                thinkingFillerTask?.cancel()
                if let queued = voiceOut.speak(speakAction) {
                    annotationController.speechQueued(
                        utteranceIdentifier: queued.utteranceNumber, group: speakAction.group,
                        anchorOffsets: queued.anchorOffsets)
                }
            case .action(.meta), .action(.end):
                break
            case .action(.outline), .action(.verdict), .action(.goalDone):
                break
            case .action(.step(let step)):
                guard fromModel else { break }
                Self.dispatchLog.notice("Script dispatch: walkthrough step received")
                if walkthroughController.isActive { break }
                voiceOut.stop()
                adoptWalkthroughIfAnswering()
                currentTurnTask?.cancel()
                currentTurnTask = nil
                if let sessionIdentifier, let client = engineHost.client {
                    Task { await client.abort(sessionIdentifier: sessionIdentifier) }
                }
                _ = step  // task intent goes to the sole rolling planner, not this streamed list
            case .action(let action)
            where fromModel && currentTurnPurpose.walkthroughToken != nil
                && Self.isDrawing(action):
                // A plan only plans; Chalk circles each step itself when it runs it (D74). (One
                // condition for all three kinds: a `where` on a multi-pattern case guards only
                // the last pattern, which once dropped every circle, D76.)
                break
            case .action(.remember(let rememberAction)):
                userData.apply(rememberAction)
            case .action(let action):
                if case .figure = action {
                    Self.dispatchLog.notice("Script dispatch: whiteboard figure received")
                }
                annotationController.handle(action)
            case .diagnostic(let diagnostic):
                // Parser diagnostics may contain response text: expose presence, not contents.
                let diagnosticKind: String
                switch diagnostic {
                case .unknownType: diagnosticKind = "unknownType"
                case .outOfDemoScope: diagnosticKind = "outOfDemoScope"
                case .invalidAction: diagnosticKind = "invalidAction"
                case .downgradedToSpeechOnly: diagnosticKind = "downgradedToSpeechOnly"
                case .lowConfidenceTarget: diagnosticKind = "lowConfidenceTarget"
                case .malformedJSON: diagnosticKind = "malformedJSON"
                case .repaired: diagnosticKind = "repaired"
                case .overlongLineSpokenAsText: diagnosticKind = "overlongLineSpokenAsText"
                case .unsupportedVersion: diagnosticKind = "unsupportedVersion"
                case .plainTextDropped: diagnosticKind = "plainTextDropped"
                }
                Self.dispatchLog.notice(
                    "Script parser diagnostic: \(diagnosticKind, privacy: .public) (content omitted)"
                )
                print("📜 Turn: script \(diagnostic)")
            }
        }
    }

    private static func isDrawing(_ action: ScriptAction) -> Bool {
        switch action {
        case .draw, .point, .highlight: return true
        default: return false
        }
    }

    /// D69: an ordinary answer that guides with steps (a task said plainly) becomes a
    /// walkthrough, rather than the steps being dropped.
    private func adoptWalkthroughIfAnswering() {
        guard !walkthroughController.isActive, case .answer = currentTurnPurpose else { return }
        let token = walkthroughController.adoptPlan(
            goal: currentTurnTranscript, appName: frontmostAppName)
        adoptedWalkthrough = (turnSerial, token)
    }

    #if DEBUG
        /// S4 sync check (§11.2, DEMO_PLAN S06): a fixed script with five anchors on region targets,
        /// spoken and drawn locally with no model and no screenshot. Each drawing logs
        /// `🖍️ sync … strokeDelayMs=…`; Eval/s4-sync.sh turns those into p50/p95.
        // swift-format-ignore: LineLength
        static let localDrawingTestScript = [
            #"{"type":"meta","v":1}"#,
            #"{"type":"speak","text":"Up here, {a1}this corner is where the menus live, and {a2}this side has the status icons.","group":"g1"}"#,
            #"{"type":"draw","shape":"ellipse","target":{"region":{"x":0.02,"y":0.0,"w":0.18,"h":0.04}},"at":"a1","group":"g1","id":"s4-a1"}"#,
            #"{"type":"draw","shape":"rect","target":{"region":{"x":0.72,"y":0.0,"w":0.26,"h":0.04}},"at":"a2","group":"g1","role":"explain","id":"s4-a2"}"#,
            #"{"type":"speak","text":"The middle of the screen is {a3}your workspace.","group":"g2"}"#,
            #"{"type":"draw","shape":"underline","target":{"region":{"x":0.35,"y":0.45,"w":0.3,"h":0.06}},"at":"a3","group":"g2","role":"correct","id":"s4-a3"}"#,
            #"{"type":"speak","text":"And down at the bottom, {a4}the Dock, {a5}right about here.","group":"g3"}"#,
            #"{"type":"draw","shape":"arrow","target":{"region":{"x":0.42,"y":0.9,"w":0.16,"h":0.08}},"at":"a4","group":"g3","role":"mistake","label":"the Dock","id":"s4-a4"}"#,
            #"{"type":"draw","shape":"ring","target":{"region":{"x":0.48,"y":0.92,"w":0.04,"h":0.05}},"at":"a5","id":"s4-a5"}"#,
            #"{"type":"end"}"#,
        ]

        /// Demo script step 3 (§4.7): "why 0.999… = 1" as math steps revealed line by line (S10).
        // swift-format-ignore: LineLength
        static let localMathStepsTestScript = [
            #"{"type":"speak","group":"g1","text":"Let's prove it."}"#,
            #"{"type":"figure","kind":"math_steps","surface":"board","id":"f1","at":"a1","spec":{"title":"Why 0.999… = 1","steps":["x = 0.\\overline{9}","10x = 9.\\overline{9}","10x - x = 9.\\overline{9} - 0.\\overline{9}","9x = 9","x = \\frac{9}{9} = 1"]}}"#,
            #"{"type":"speak","group":"g2","text":"Call the number x, so {a1}x equals zero point nine repeating."}"#,
            #"{"type":"reveal","id":"f1","part":1,"at":"a2"}"#,
            #"{"type":"speak","group":"g3","text":"Multiply both sides by ten: {a2}ten x is nine point nine repeating."}"#,
            #"{"type":"reveal","id":"f1","part":2,"at":"a3"}"#,
            #"{"type":"reveal","id":"f1","part":3,"at":"a4"}"#,
            #"{"type":"speak","group":"g4","text":"Subtract the first line, {a3}and the endless nines cancel, {a4}so nine x is nine."}"#,
            #"{"type":"reveal","id":"f1","part":4,"at":"a5"}"#,
            #"{"type":"speak","group":"g5","text":"Divide by nine, and {a5}x is exactly one."}"#,
            #"{"type":"end"}"#,
        ]

        /// The number line half of demo step 3 (S10).
        // swift-format-ignore: LineLength
        static let localNumberLineTestScript = [
            #"{"type":"speak","group":"g1","text":"Let's walk toward one on a number line."}"#,
            #"{"type":"figure","kind":"numberline","surface":"board","id":"f2","spec":{"min":0.8,"max":1,"ticks":[0.8,0.85,0.9,0.95,1],"marks":[{"value":0.9,"label":"0.9"},{"value":0.99,"label":"0.99"},{"value":1,"label":"0.999… = 1"}],"intervals":[{"from":0.99,"to":1,"label":"gap shrinks to 0"}]}}"#,
            #"{"type":"speak","group":"g2","text":"Zero point nine {a1}is here."}"#,
            #"{"type":"reveal","id":"f2","part":1,"at":"a2"}"#,
            #"{"type":"speak","group":"g3","text":"Add a nine, {a2}zero point nine nine, closer."}"#,
            #"{"type":"reveal","id":"f2","part":2,"at":"a3"}"#,
            #"{"type":"reveal","id":"f2","part":3,"at":"a4"}"#,
            #"{"type":"speak","group":"g4","text":"With endless nines {a3}you land on one, because {a4}the gap shrinks to nothing."}"#,
            #"{"type":"end"}"#,
        ]

        /// A right triangle on the board (geometry, D59).
        // swift-format-ignore: LineLength
        static let localGeometryTestScript = [
            #"{"type":"speak","group":"g1","text":"Let's draw a right triangle."}"#,
            #"{"type":"figure","kind":"geometry","surface":"board","id":"f3","spec":{"title":"Right triangle","points":{"A":[0,0],"B":[4,0],"C":[0,3]},"segments":[{"from":"A","to":"B","label":"4"},{"from":"B","to":"C","label":"5"},{"from":"C","to":"A","label":"3"}],"angles":[{"at":"A","right":true},{"at":"B","label":"θ"}]}}"#,
            #"{"type":"reveal","id":"f3","part":1,"at":"a1"}"#,
            #"{"type":"speak","group":"g2","text":"The corner at A is {a1}a right angle, ninety degrees."}"#,
            #"{"type":"reveal","id":"f3","part":2,"at":"a2"}"#,
            #"{"type":"speak","group":"g3","text":"And this {a2}angle at B is the one we'll call theta."}"#,
            #"{"type":"end"}"#,
        ]

        func runLocalDrawingTest() {
            runLocalScript(Self.localDrawingTestScript)
        }

        func runLocalScript(_ script: [String]) {
            stopSpeakingAndDrawing()
            let mouseLocation = NSEvent.mouseLocation
            guard
                let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                    ?? NSScreen.main
            else { return }
            let nativeSize = CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor)
            let screenSpace = ScreenSpace(
                displayFrameInAppKitGlobal: screen.frame, nativePixelSize: nativeSize,
                modelPixelSize: ScreenSpace.modelPixelSize(forNativePixelSize: nativeSize))
            annotationController.beginTurn(
                screenSpace: screenSpace, marks: [], snapTargets: [], cursorInNativePixels: nil)
            var parser = StreamingScriptParser()
            handle(parser.feed(script.joined(separator: "\n") + "\n"))
            handle(parser.finish())
            annotationController.scriptFinished()
        }
    #endif

    private func scheduleAcknowledgement(afterMilliseconds delayMilliseconds: Int) {
        acknowledgementTask?.cancel()
        thinkingFillerTask?.cancel()
        acknowledgementTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, !Task.isCancelled, !self.hasQueuedAnswerSpeechThisTurn,
                !self.hasSpokenFillerThisTurn
            else { return }
            let phrase = Self.acknowledgementPhrases.randomElement() ?? "One moment."
            self.hasSpokenAcknowledgementThisTurn = true
            self.voiceOut.speak(SpeakAction(text: phrase), isAcknowledgement: true)
        }
    }

    /// D63: while a teaching or deep model reasons (Sonnet took ~15 s on a worked solution), the
    /// fast slot writes one line about the question itself from the transcript and the text near
    /// the pointer; it is spoken only if the answer hasn't started. If the answer is still not
    /// there a while later, one short progress line follows. Reasoning stays on (owner).
    private func startThinkingFiller(
        transcript: String, screen: (capture: ScreenCaptureResult, perception: ScreenPerception?)?
    ) {
        guard let client = engineHost.client, let router = engineHost.router,
            let fastModel = try? router.candidateModels(for: .fast, requiresVision: false).first
        else { return }
        let isWorkedSolution = QuestionContext.isWorkedSolution(transcript)
        var nearbyText: String?
        if let screen, let cursor = screen.capture.cursorInNativePixels,
            let marks = screen.perception?.snapTargets
        {
            nearbyText = ThinkingFiller.nearbyText(
                marks: marks,
                within: QuestionContext.cropAroundPointer(
                    cursorInNativePixels: cursor, screenSpace: screen.capture.screenSpace))
        }
        let prompt = ThinkingFiller.prompt(
            question: transcript, nearbyText: nearbyText, isWorkedSolution: isWorkedSolution)
        thinkingFillerTask?.cancel()
        thinkingFillerTask = Task { [weak self] in
            let reply = await GroundingService.collectReply(
                // The fast path (D74): no agent loop, no rule files for one spoken line.
                from: await client.completeTurn(
                    slot: ModelSlot.fast.rawValue, model: fastModel,
                    system: Self.fastPathSystemPrompt, prompt: prompt, maxTokens: 8192),
                timeoutSeconds: Self.thinkingFillerTimeoutSeconds)
            guard let self, !Task.isCancelled, !self.hasQueuedAnswerSpeechThisTurn,
                !self.hasSpokenAcknowledgementThisTurn,
                let line = reply.flatMap(ThinkingFiller.spokenLine(fromReply:))
            else { return }
            self.hasSpokenFillerThisTurn = true
            self.voiceOut.speak(SpeakAction(text: line), isAcknowledgement: true)
            // No second "still working" line (D72): it was one more start before the answer.
        }
    }

    private func finishTurn() {
        acknowledgementTask?.cancel()
        thinkingFillerTask?.cancel()
        lastTurnFinishedAt = Date()
        timeline.isFinished = true
        logTimelineIfComplete()
    }

    private func speakFailure(_ message: String) {
        acknowledgementTask?.cancel()
        thinkingFillerTask?.cancel()
        voiceOut.speak(SpeakAction(text: message))
    }

    private static func spokenMessage(for engineError: EngineError) -> String {
        switch engineError.kind {
        case "auth":
            return "I'm not signed in to Cline. Run the Cline sign-in script, then ask me again."
        case "rate_limit": return "I've hit my usage limit for a moment. Try again in a bit."
        case "network": return "I can't reach the internet right now."
        default: return "Sorry, something went wrong. Try asking again."
        }
    }

    // MARK: - Latency log (§11.3)

    /// Logs once the turn has ended and its first word has played (either can happen last), or
    /// right away when nothing will be spoken.
    private func logTimelineIfComplete() {
        guard timeline.isFinished else { return }
        guard timeline.firstAnswerWord != nil || !hasQueuedAnswerSpeechThisTurn else { return }
        logTimeline()
    }

    private func logTimeline() {
        guard timeline.keyDown != nil else { return }
        if let signpostState {
            Self.signposter.endInterval("turn", signpostState)
            self.signpostState = nil
        }
        func milliseconds(_ from: Date?, _ to: Date?) -> String {
            guard let from, let to else { return "–" }
            return "\(Int((to.timeIntervalSince(from) * 1000).rounded()))"
        }
        let keyUp = timeline.keyUp ?? timeline.transcriptFinal
        let line =
            "⏱️ turn \(timeline.outcome) slot=\(timeline.slot?.rawValue ?? "–") model=\(timeline.model ?? "–") | "
            + "keyUp→firstWord \(milliseconds(keyUp, timeline.firstAnswerWord)) ms "
            + "(→transcript \(milliseconds(keyUp, timeline.transcriptFinal)), →request \(milliseconds(keyUp, timeline.requestSent)), "
            + "→firstText \(milliseconds(keyUp, timeline.firstText)), →speakLine \(milliseconds(keyUp, timeline.firstSpeakLine))) | "
            + "ack \(timeline.acknowledgementWord == nil ? "no" : milliseconds(keyUp, timeline.acknowledgementWord) + " ms")"
        // One line per turn; the unified log also shows in the Xcode console, so no print.
        Self.latencyLog.info("\(line, privacy: .public)")
        timeline.keyDown = nil
    }
}
