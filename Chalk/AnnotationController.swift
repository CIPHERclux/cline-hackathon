//
//  AnnotationController.swift
//  Chalk
//
//  Turns Teaching Script drawing actions into marks on screen (§4.2, §6.5), timed to speech:
//  resolve the target against the current capture (§6.2) → a guess with nothing to snap to gets
//  the zoom pass first (§6.2 d) → wait for the spoken anchor (§4.2.4) → register under the
//  lifecycle rules and ink budget (§4.2.2) → draw → verify text targets with a fresh crop
//  (§6.2 f). The rules live in ChalkCore (AnchorScheduler, LifecycleRegistry, TargetResolver,
//  VerificationCheck, ZoomPass, RoughStrokeGenerator); this class wires them to TTS events, the
//  grounding service, a one-shot transient timer and the renderer.
//

import AppKit
import ChalkCore
import os

@MainActor
final class AnnotationController {
    private struct PendingMark {
        let markIdentifier: String
        let drawRequest: AnnotationDrawRequest?
        let lifecycle: MarkLifecycle
        let ink: InkKind
        let anchor: String?
        /// Overlay-local target, so a `point` and a drawing on the same thing become one mark.
        let targetRect: CGRect?
        let isPoint: Bool
        /// The on-screen text the target landed on, re-read after drawing (§6.2 f).
        var expectedText: String? = nil
        /// Rebuilds the drawing around another overlay-local rect (verification relocation).
        var rebuild: ((CGRect) -> AnnotationDrawRequest?)? = nil
        /// Whiteboard figures and reveals (S10) run this instead of drawing on the screen.
        var onStart: (() -> Void)? = nil
        /// A reveal only changes its figure; it isn't a mark of its own.
        var registersMark = true
    }

    /// Where a target landed (§6.2).
    private enum TargetResolution {
        case resolved(displayRect: CGRect, matchedText: String?)
        /// A guess with nothing under it (native pixels): the zoom pass looks again.
        case guessed(nativePoint: CGPoint, displayRect: CGRect)
        case unresolved
    }

    private static let syncLog = Logger(subsystem: "com.chalk.app", category: "sync")
    /// How long a speech-bound mark stays after its sentence group ends (D58).
    static let lingerAfterSpeechSeconds = 1.5
    /// A walkthrough circle's verification move is ignored beyond this (D73).
    static let largestStepMarkRelocationPoints: CGFloat = 120

    private let renderer = AnnotationRenderer()
    private var registry = LifecycleRegistry()
    private var scheduler = AnchorScheduler()
    private var resolver: TargetResolver?
    private var screenSpace: ScreenSpace?
    private var pendingMarks: [String: PendingMark] = [:]
    private var automaticIdentifierCounter = 0
    private var transientExpiryWorkItem: DispatchWorkItem?
    private let clockOrigin = Date()

    /// The pen (D50) took over from the buddy cursor (true) or handed it back (false).
    var onPenActiveChanged: ((Bool) -> Void)? {
        get { renderer.onPenActiveChanged }
        set { renderer.onPenActiveChanged = newValue }
    }
    /// Targets of pending and live `point` marks, to drop a ring that a drawing duplicates.
    private var pointTargets: [String: (rect: CGRect, anchor: String?)] = [:]
    /// Set once the turn's speech is done; the last transient expiry then checks P-LEFTOVER.
    private var isTurnOver = false

    /// Verification and the zoom pass (S08); nil in the local drawing test.
    var groundingService: GroundingService?
    /// §5.10 low confidence: "I'm not sure exactly where. Can you circle it?" (once per turn).
    var onAskLearnerToCircle: (() -> Void)?
    private var capture: ScreenCaptureResult?
    /// §4.2.9 whiteboard (S10): `numberline` and `math_steps` figures.
    let whiteboard = WhiteboardPanel()
    private var revealCounter = 0
    /// Out of the registry (their sentences ended) but still on screen for a moment (D58);
    /// cleanup removes them at once.
    private var lingeringMarks: Set<String> = []
    private var learnerQuestion = ""
    private var escalation = GroundingEscalation()
    private var hasAskedToCircleThisTurn = false
    /// A target couldn't be placed; the ask waits for the end of the answer (D60).
    private var wantsToAskLearnerToCircle = false
    /// Anything shown this turn (a mark or a board figure): then one miss isn't worth an ask.
    private var hasShownSomethingThisTurn = false
    private var zoomPassesInFlight = 0
    /// Bumped by every new turn and cleanup, so late zoom or verify results are dropped.
    private var turnGeneration = 0

    /// A walkthrough step is waiting (§4.2.6): its `stepBound` marks stay after the sentence
    /// and the turn end, until the step completes (§4.2.2 rule 1).
    var keepsStepMarks = false
    /// Where the walkthrough step's circle is, in AppKit global points: a click there is "on
    /// the control" for the check turn (D70).
    private(set) var stepTargetRectInAppKitGlobal: CGRect?

    var hasLiveMarks: Bool {
        !registry.entries.isEmpty || !pendingMarks.isEmpty || zoomPassesInFlight > 0
    }

    private var now: TimeInterval { Date().timeIntervalSince(clockOrigin) }

    init() {
        // Closing the board ends its `board` mark (§4.2.2), so the registry stays exact.
        whiteboard.onClosed = { [weak self] figureIdentifier in
            guard let self else { return }
            _ = self.registry.clear(identifiers: [figureIdentifier])
        }
        // The buddy writes on the board with the same pen it draws with (D57).
        whiteboard.movePen = { [weak self] path, displayFrame, duration in
            self?.renderer.movePenAlong(path, displayFrame: displayFrame, durationSeconds: duration)
                ?? 0
        }
    }

    // MARK: - Turn lifecycle

    /// The screen this turn's targets resolve against; nil means no screenshot (speech only).
    func beginTurn(capture: ScreenCaptureResult?, perception: ScreenPerception?, question: String) {
        learnerQuestion = question
        beginTurn(
            screenSpace: capture?.screenSpace, marks: perception?.marks ?? [],
            snapTargets: perception?.snapTargets ?? [],
            cursorInNativePixels: capture?.cursorInNativePixels)
        self.capture = capture
    }

    /// Also used by the local drawing test, which resolves region targets without a capture.
    func beginTurn(
        screenSpace: ScreenSpace?, marks: [Mark], snapTargets: [Mark],
        cursorInNativePixels: CGPoint?
    ) {
        isTurnOver = false
        scheduler.reset()
        pendingMarks.removeAll()
        pointTargets.removeAll()
        capture = nil
        escalation.reset()
        hasAskedToCircleThisTurn = false
        wantsToAskLearnerToCircle = false
        hasShownSomethingThisTurn = false
        turnGeneration += 1
        self.screenSpace = screenSpace
        resolver = screenSpace.map {
            TargetResolver(
                screenSpace: $0, marks: marks, snapTargets: snapTargets,
                cursorInNativePixels: cursorInNativePixels)
        }
    }

    func speechQueued(utteranceIdentifier: Int, group: String?, anchorOffsets: [String: Int]) {
        scheduler.utteranceQueued(
            utteranceIdentifier: utteranceIdentifier, group: group, anchorOffsets: anchorOffsets)
    }

    func rangeWillBeSpoken(utteranceIdentifier: Int, range: NSRange, anchorReachedAt: Date) {
        for markIdentifier in scheduler.rangeWillBeSpoken(
            utteranceIdentifier: utteranceIdentifier, range: range)
        {
            start(markIdentifier, cause: .anchorWord(spokenAt: anchorReachedAt))
        }
    }

    func utteranceFinished(utteranceIdentifier: Int) {
        let (drawingsToStart, finishedGroups) = scheduler.utteranceFinished(
            utteranceIdentifier: utteranceIdentifier)
        for markIdentifier in drawingsToStart { start(markIdentifier, cause: .utteranceEnd) }
        for group in finishedGroups {
            // Marks stay a moment after their sentences so the learner can take them in (D58).
            let finishedMarks = registry.groupFinished(group)
            lingeringMarks.formUnion(finishedMarks)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerAfterSpeechSeconds) {
                [weak self] in
                guard let self else { return }
                let stillLingering = finishedMarks.filter { self.lingeringMarks.contains($0) }
                self.lingeringMarks.subtract(stillLingering)
                self.renderer.fade(markIdentifiers: stillLingering)
            }
        }
    }

    /// The script stream ended: drawings whose anchor no speak line declared draw now.
    func scriptFinished() {
        for markIdentifier in scheduler.flushUndeclared() { start(markIdentifier, cause: .arrival) }
    }

    /// Cleanup triggers (§4.2.2 rule 3: talk key, Esc, stop) clear within 150 ms; the end of a
    /// turn uses the normal 400 ms fade. Either way the registry must end empty (P-LEFTOVER).
    func clearAll(fast: Bool) {
        turnGeneration += 1
        zoomPassesInFlight = 0
        transientExpiryWorkItem?.cancel()
        transientExpiryWorkItem = nil
        pendingMarks.removeAll()
        pointTargets.removeAll()
        scheduler.reset()
        whiteboard.finishWritingInstantly()
        renderer.sendPenHome(animated: !fast)
        stepTargetRectInAppKitGlobal = nil
        let cleared = registry.clearAllExceptPinnedAndBoard() + Array(lingeringMarks)
        lingeringMarks.removeAll()
        renderer.fade(
            markIdentifiers: cleared,
            seconds: fast
                ? AnnotationRenderer.cleanupFadeSeconds : AnnotationRenderer.fadeOutSeconds)
        assertNoLeftovers()
    }

    /// A Space switch (§6.6 skill note: non-pinned marks clear): the marks no longer sit over
    /// what they marked. The answer goes on, so pending drawings and anchors are kept.
    func clearVisibleMarks() {
        renderer.sendPenHome(animated: false)
        renderer.fade(
            markIdentifiers: registry.clearAllExceptPinnedAndBoard(),
            seconds: AnnotationRenderer.cleanupFadeSeconds)
    }

    /// Displays were added, removed or rearranged (P-DISPLAYS): marks clear and the
    /// per-display windows are rebuilt on the next draw.
    func displaysChanged() {
        clearAll(fast: true)
        renderer.discardWindows()
    }

    func setHiddenForScreenshot(_ hidden: Bool) {
        renderer.setHiddenForScreenshot(hidden)
    }

    func applySharingType() {
        renderer.applySharingType()
    }

    /// Terminal state (§4.2.2 rule 5): the answer is fully spoken. Speech-bound marks fade now,
    /// and step marks too unless a walkthrough step is waiting on them; transient rings finish
    /// their 2 s, after which the registry must be empty.
    func turnEnded() {
        askLearnerToCircleIfNothingWasShown()
        isTurnOver = true
        // Parts the script never revealed show now, so the board is complete after the answer.
        whiteboard.revealAll()
        pendingMarks.removeAll()
        scheduler.reset()
        let speechAndStepMarks = registry.entries.filter {
            switch $0.lifecycle {
            case .speechBound: return true
            case .stepBound: return !keepsStepMarks
            case .transient, .pinned, .board: return false
            }
        }
        renderer.fade(
            markIdentifiers: registry.clear(identifiers: speechAndStepMarks.map(\.identifier)))
        if registry.nextTransientExpiry == nil { assertNoLeftovers() }
    }

    /// `rect` is overlay-local (display points, top-left) on the current screen.
    private func noteStepTarget(_ rect: CGRect?) {
        guard let rect, let frame = screenSpace?.displayFrameInAppKitGlobal else { return }
        stepTargetRectInAppKitGlobal = CGRect(
            x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width,
            height: rect.height)
    }

    /// The walkthrough step completed or changed: its marks fade.
    func clearStepMarks() {
        stepTargetRectInAppKitGlobal = nil
        let stepMarks = registry.entries.filter { $0.lifecycle == .stepBound }.map(\.identifier)
        let pendingStepMarks = pendingMarks.filter { $0.value.lifecycle == .stepBound }.map(\.key)
        for identifier in pendingStepMarks { pendingMarks.removeValue(forKey: identifier) }
        guard !stepMarks.isEmpty else { return }
        renderer.fade(
            markIdentifiers: registry.clear(identifiers: stepMarks),
            seconds: AnnotationRenderer.cleanupFadeSeconds)
        renderer.sendPenHome(animated: true)
    }

    private func assertNoLeftovers() {
        let leftovers = registry.entries.filter {
            switch $0.lifecycle {
            case .pinned, .board: return false
            case .stepBound: return !keepsStepMarks
            case .transient, .speechBound: return true
            }
        }
        if !leftovers.isEmpty {
            Self.syncLog.fault(
                "P-LEFTOVER: marks left: \(self.registry.liveIdentifiers, privacy: .public)")
        }
    }

    // MARK: - Script actions

    func handle(_ action: ScriptAction) {
        switch action {
        case .draw(let draw):
            enqueue(
                makeDrawing(
                    shape: draw.shape, target: draw.target, from: draw.from, to: draw.to,
                    label: draw.label, role: draw.role,
                    identifier: draw.identifier, anchor: draw.anchor,
                    lifecycle: MarkLifecycle.forDrawing(
                        shape: draw.shape, life: draw.life, group: draw.group)))
        case .highlight(let highlight):
            enqueue(
                makeDrawing(
                    shape: .highlight, target: highlight.target, from: nil, to: nil, label: nil,
                    role: "explain",
                    identifier: nil, anchor: highlight.anchor,
                    lifecycle: MarkLifecycle.forDrawing(
                        shape: .highlight, life: highlight.life, group: nil)))
        case .point(let point):
            enqueue(makePoint(point))
        case .clear(let clear):
            switch clear.scope {
            case .all:
                let cleared = registry.clearAllExceptPinnedAndBoard()
                renderer.fade(
                    markIdentifiers: cleared, seconds: Double(clear.fadeMilliseconds ?? 400) / 1000)
            case .identifiers(let identifiers):
                for identifier in identifiers { pendingMarks.removeValue(forKey: identifier) }
                renderer.fade(
                    markIdentifiers: registry.clear(identifiers: identifiers),
                    seconds: Double(clear.fadeMilliseconds ?? 400) / 1000)
            }
        case .figure(let figure):
            enqueue(makeFigure(figure))
        case .reveal(let reveal):
            revealCounter += 1
            let figureIdentifier = reveal.identifier
            let part = reveal.part.integerValue
            enqueue(
                PendingMark(
                    markIdentifier: "reveal\(revealCounter)", drawRequest: nil,
                    lifecycle: .transient,
                    ink: .emphasis, anchor: reveal.anchor, targetRect: nil, isPoint: false,
                    onStart: { [weak self] in
                        self?.whiteboard.reveal(part: part, identifier: figureIdentifier)
                    },
                    registersMark: false))
        default:
            // check, wait_*: later slices (S12–S13).
            print("🖍️ Annotation: not drawn yet: \(action)")
        }
    }

    // MARK: - Private

    private func enqueue(_ pendingMark: PendingMark?) {
        guard let pendingMark else { return }
        // Models often send a `point` and a drawing for the same thing at the same word (seen
        // with Flash Lite, D50): keep the drawing, drop the point's ring.
        if let targetRect = pendingMark.targetRect {
            if pendingMark.isPoint {
                let isDuplicated = pendingMarks.values.contains {
                    !$0.isPoint && $0.anchor == pendingMark.anchor
                        && Self.isSameTarget($0.targetRect, targetRect)
                }
                if isDuplicated { return }
                pointTargets[pendingMark.markIdentifier] = (targetRect, pendingMark.anchor)
            } else {
                let duplicatePoints = pointTargets.filter {
                    $0.value.anchor == pendingMark.anchor
                        && Self.isSameTarget($0.value.rect, targetRect)
                }.map(\.key)
                for identifier in duplicatePoints {
                    pointTargets.removeValue(forKey: identifier)
                    pendingMarks.removeValue(forKey: identifier)
                }
                renderer.fade(
                    markIdentifiers: registry.clear(identifiers: duplicatePoints),
                    seconds: AnnotationRenderer.cleanupFadeSeconds)
            }
        }
        pendingMarks[pendingMark.markIdentifier] = pendingMark
        if scheduler.drawingArrived(
            markIdentifier: pendingMark.markIdentifier, anchor: pendingMark.anchor)
        {
            start(pendingMark.markIdentifier, cause: .arrival)
        }
    }

    /// Why a drawing starts: its anchor word, its arrival (no anchor, unknown anchor, or the word
    /// already passed: the script line was late), or the end of its utterance (TTS skipped the
    /// word's range callback).
    private enum StartCause {
        case anchorWord(spokenAt: Date)
        case arrival
        case utteranceEnd
    }

    private func start(_ markIdentifier: String, cause: StartCause) {
        guard let pendingMark = pendingMarks.removeValue(forKey: markIdentifier) else { return }
        if pendingMark.registersMark {
            let evicted = registry.add(
                identifier: markIdentifier, lifecycle: pendingMark.lifecycle, ink: pendingMark.ink,
                now: now)
            renderer.fade(markIdentifiers: evicted)
        }
        pendingMark.onStart?()
        if pendingMark.lifecycle == .stepBound { noteStepTarget(pendingMark.targetRect) }
        if pendingMark.drawRequest != nil || pendingMark.lifecycle == .board {
            hasShownSomethingThisTurn = true
        }
        var penApproachSeconds = 0.0
        if let drawRequest = pendingMark.drawRequest {
            // The pen (the buddy cursor) flies there and draws it, `point` included (§6.4, D50).
            // Step circles too: the owner wants the pointer to go where Chalk circles (D86).
            penApproachSeconds = renderer.draw(drawRequest, usesPen: true)
        }
        scheduleTransientExpiry()
        verifyAfterDrawing(pendingMark)
        // S4 sync measurement (§11.2: stroke onset within 150 ms of the anchor word, p95);
        // Eval/s4-sync.sh reads these lines. strokeDelayMs is when the mark (or the pen flying
        // to it) starts moving; the ink itself begins penApproachMs later (D50). Late and
        // utterance-end starts count as misses.
        guard let anchor = pendingMark.anchor else { return }
        let outcome: String
        switch cause {
        case .anchorWord(let spokenAt):
            outcome = String(
                format: "strokeDelayMs=%.1f penApproachMs=%.0f",
                Date().timeIntervalSince(spokenAt) * 1000, penApproachSeconds * 1000)
        case .arrival: outcome = "miss=late"
        case .utteranceEnd: outcome = "miss=utteranceEnd"
        }
        // .notice, not .info: info lines aren't reliably kept, and the S4 script reads the log.
        Self.syncLog.notice(
            "🖍️ sync mark=\(markIdentifier, privacy: .public) anchor=\(anchor, privacy: .public) \(outcome, privacy: .public)"
        )
    }

    /// One one-shot timer for the next transient expiry, only while transient marks exist (P-IDLECPU).
    private func scheduleTransientExpiry() {
        transientExpiryWorkItem?.cancel()
        transientExpiryWorkItem = nil
        guard let expiry = registry.nextTransientExpiry else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderer.fade(markIdentifiers: self.registry.expireTransients(now: self.now))
            self.scheduleTransientExpiry()
            if self.isTurnOver, self.registry.nextTransientExpiry == nil {
                self.assertNoLeftovers()
            }
        }
        transientExpiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, expiry - now) + 0.01, execute: workItem)
    }

    private func nextIdentifier(_ explicitIdentifier: String?, prefix: String) -> String {
        if let explicitIdentifier { return explicitIdentifier }
        automaticIdentifierCounter += 1
        return "\(prefix)\(automaticIdentifierCounter)"
    }

    /// Native-pixel rect → overlay-local points on its display.
    private func displayRect(_ target: TargetDescriptor?) -> CGRect? {
        guard let target, let resolver, let screenSpace else { return nil }
        guard let resolved = resolver.resolve(target) else { return nil }
        if resolved.isLowConfidence {
            print("📜 Annotation: low-confidence target \(target) (\(resolved.source.rawValue))")
        }
        return screenSpace.nativePixelRectToDisplayPoints(resolved.rectInNativePixels)
    }

    private func makeDrawing(
        shape: AnnotationShape, target: TargetDescriptor?, from: TargetDescriptor?,
        to: TargetDescriptor?, label: String?,
        role: String?, identifier: String?, anchor: String?, lifecycle: MarkLifecycle,
        zoomedTargetRect: CGRect? = nil
    ) -> PendingMark? {
        guard let screenSpace else {
            print("📜 Annotation: no screen this turn; \(shape.rawValue) becomes speech-only")
            return nil
        }
        let markIdentifier = nextIdentifier(identifier, prefix: "auto")
        let seed = SeededRandom.seed(for: markIdentifier)
        var targetRect = zoomedTargetRect
        var matchedText: String?
        if zoomedTargetRect == nil, shape != .arrow, shape != .curvedArrow {
            switch resolveTarget(target) {
            case .resolved(let displayRect, let text):
                targetRect = displayRect
                matchedText = text
            case .guessed(let nativePoint, let displayRect):
                // §6.2 (d): draw the guess on its word, and let a zoomed second look move it.
                refineWithZoom(
                    markIdentifier: markIdentifier, around: nativePoint,
                    lookingFor: label ?? describe(target)
                ) { [weak self] zoomedRect in
                    self?.makeDrawing(
                        shape: shape, target: target, from: from, to: to, label: label, role: role,
                        identifier: markIdentifier, anchor: anchor, lifecycle: lifecycle,
                        zoomedTargetRect: zoomedRect)
                }
                targetRect = displayRect
            case .unresolved:
                askLearnerToCircle()
                return downgraded(shape, markIdentifier)
            }
        } else if zoomedTargetRect == nil {
            targetRect = displayRect(target)
        }
        var markedRect = targetRect
        let drawing: RoughDrawing
        var labelAnchor: CGPoint?
        var zOrder: CGFloat = 2
        switch shape {
        case .arrow, .curvedArrow:
            let fromRect = displayRect(from)
            guard let toRect = displayRect(to) ?? targetRect else {
                return downgraded(shape, markIdentifier)
            }
            markedRect = toRect
            let end = CGPoint(x: toRect.midX, y: toRect.midY)
            // Without a source, come in from the upper left, ending just short of the target.
            let start =
                fromRect.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? CGPoint(x: end.x - 90, y: end.y - 70)
            let inset = Self.pointShortOfEdge(from: start, to: end, rect: toRect)
            drawing =
                shape == .arrow
                ? RoughStrokeGenerator.arrow(from: start, to: inset, seed: seed)
                : RoughStrokeGenerator.curvedArrow(from: start, to: inset, seed: seed)
            zOrder = 3
        default:
            guard let rect = targetRect else { return downgraded(shape, markIdentifier) }
            switch shape {
            case .ring: drawing = Self.ringDrawing(around: rect, seed: seed)
            case .ellipse: drawing = Self.encircling(rect, seed: seed)
            case .rect: drawing = RoughStrokeGenerator.rectangle(around: rect, seed: seed)
            case .underline: drawing = RoughStrokeGenerator.underline(below: rect, seed: seed)
            case .highlight:
                drawing = RoughStrokeGenerator.highlight(over: rect, seed: seed)
                zOrder = 1
            case .label, .stepBadge:
                // A small ring on the target and the text chip beside it.
                drawing = RoughStrokeGenerator.ring(
                    around: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(18, max(rect.width, rect.height) / 2 + 8), seed: seed)
                zOrder = 4
            default: return downgraded(shape, markIdentifier)
            }
            labelAnchor = CGPoint(x: rect.maxX + 10, y: rect.midY)
        }
        let request = AnnotationDrawRequest(
            markIdentifier: markIdentifier, drawing: drawing,
            role: AnnotationColorRole(scriptRole: role),
            label: label ?? (shape == .stepBadge ? "1" : nil), labelAnchor: labelAnchor,
            zOrder: zOrder,
            displayFrameInAppKitGlobal: screenSpace.displayFrameInAppKitGlobal)
        return PendingMark(
            markIdentifier: markIdentifier, drawRequest: request, lifecycle: lifecycle,
            ink: InkKind.forShape(shape), anchor: anchor, targetRect: markedRect, isPoint: false,
            expectedText: matchedText,
            rebuild: { [weak self] relocatedRect in
                self?.makeDrawing(
                    shape: shape, target: target, from: from, to: to, label: label, role: role,
                    identifier: markIdentifier, anchor: anchor, lifecycle: lifecycle,
                    zoomedTargetRect: relocatedRect)?.drawRequest
            })
    }

    private func makePoint(_ point: PointAction, zoomedTargetRect: CGRect? = nil) -> PendingMark? {
        guard let screenSpace else { return nil }
        let markIdentifier = nextIdentifier(point.identifier, prefix: "point")
        var identifiedPoint = point
        identifiedPoint.identifier = markIdentifier
        let rect: CGRect
        var matchedText: String?
        if let zoomedTargetRect {
            rect = zoomedTargetRect
        } else {
            switch resolveTarget(point.target) {
            case .resolved(let displayRect, let text):
                rect = displayRect
                matchedText = text
            case .guessed(let nativePoint, let displayRect):
                refineWithZoom(
                    markIdentifier: markIdentifier, around: nativePoint,
                    lookingFor: point.label ?? describe(point.target)
                ) { [weak self] zoomedRect in
                    self?.makePoint(identifiedPoint, zoomedTargetRect: zoomedRect)
                }
                rect = displayRect
            case .unresolved:
                print("📜 Annotation: point target unresolved; speech-only")
                askLearnerToCircle()
                return nil
            }
        }
        // §6.4 point = ghost cursor + ring: the pen flies there and rings it, with its label.
        let ring = AnnotationDrawRequest(
            markIdentifier: markIdentifier,
            drawing: Self.ringDrawing(around: rect, seed: SeededRandom.seed(for: markIdentifier)),
            role: .focus, label: point.label,
            labelAnchor: CGPoint(x: rect.maxX + 10, y: rect.midY), zOrder: 2,
            displayFrameInAppKitGlobal: screenSpace.displayFrameInAppKitGlobal)
        return PendingMark(
            markIdentifier: markIdentifier, drawRequest: ring, lifecycle: .transient,
            ink: .emphasis, anchor: point.anchor, targetRect: rect, isPoint: true,
            expectedText: matchedText,
            rebuild: { [weak self] relocatedRect in
                self?.makePoint(identifiedPoint, zoomedTargetRect: relocatedRect)?.drawRequest
            })
    }

    // MARK: - Whiteboard (S10)

    /// A `figure` becomes a `board` mark that shows on the whiteboard at its anchor (§4.2.3,
    /// §4.2.9). Specs that don't parse are dropped with a log line, like any invalid action.
    private func makeFigure(_ figure: FigureAction) -> PendingMark? {
        let boardFigure: WhiteboardModel.Figure
        switch figure.kind {
        case .numberline:
            guard let spec = NumberLineSpec(json: figure.spec) else {
                Self.syncLog.error("Whiteboard rejected: unusable numberline specification")
                print("📜 Whiteboard: numberline spec unusable: \(figure.spec)")
                return nil
            }
            boardFigure = .numberLine(spec)
        case .mathSteps:
            guard let spec = MathStepsSpec(json: figure.spec) else {
                Self.syncLog.error("Whiteboard rejected: unusable math_steps specification")
                print("📜 Whiteboard: math_steps spec unusable: \(figure.spec)")
                return nil
            }
            boardFigure = .mathSteps(spec)
        case .geometry:
            guard let spec = GeometrySpec(json: figure.spec) else {
                Self.syncLog.error("Whiteboard rejected: unusable geometry specification")
                print("📜 Whiteboard: geometry spec unusable: \(figure.spec)")
                return nil
            }
            boardFigure = .geometry(spec)
        }
        if figure.surface == "screen" {
            // The demo draws figures on the board only (§4.7).
            print("📜 Whiteboard: surface \"screen\" shown on the board")
        }
        let markIdentifier = nextIdentifier(figure.identifier, prefix: "figure")
        let displayFrame = screenSpace?.displayFrameInAppKitGlobal
        // The board comes up as soon as the figure arrives, not on its anchor: models put that
        // anchor late (hand test: the board appeared at the end of the answer). Its parts are
        // still revealed on their words (D57).
        return PendingMark(
            markIdentifier: markIdentifier, drawRequest: nil, lifecycle: .board, ink: .emphasis,
            anchor: nil, targetRect: nil, isPoint: false,
            onStart: { [weak self] in
                guard let self else { return }
                // One figure at a time: a new one replaces the board's old mark.
                if let previous = self.whiteboard.model.figureIdentifier, previous != markIdentifier
                {
                    _ = self.registry.clear(identifiers: [previous])
                }
                self.whiteboard.show(
                    boardFigure, identifier: markIdentifier, onDisplay: displayFrame)
                Self.syncLog.notice("Whiteboard opened; figure dispatched successfully")
            })
    }

    // MARK: - Grounding (S08)

    private func resolveTarget(_ target: TargetDescriptor?) -> TargetResolution {
        guard let target, let resolver, let screenSpace, let resolved = resolver.resolve(target)
        else { return .unresolved }
        let displayRect = screenSpace.nativePixelRectToDisplayPoints(resolved.rectInNativePixels)
        guard resolved.isLowConfidence else {
            // An accessibility frame is exact: nothing to re-read after drawing (D74).
            return .resolved(
                displayRect: displayRect,
                matchedText: resolved.isFromAccessibility ? nil : resolved.matchedText)
        }
        print("📜 Annotation: low-confidence target \(target) (\(resolved.source.rawValue))")
        let rect = resolved.rectInNativePixels
        return .guessed(nativePoint: CGPoint(x: rect.midX, y: rect.midY), displayRect: displayRect)
    }

    /// §6.2 (d): the guess is drawn on its word (sync first, hand test 4: waiting 2–4 s for the
    /// zoom made the ring arrive after the sentence), and the zoom pass moves it when it answers:
    /// a pending mark is rebuilt in place, a drawn one is redrawn by the pen. "Not found" means
    /// the guess was likely wrong, so the mark goes and Chalk asks to have it circled (§5.10).
    private func refineWithZoom(
        markIdentifier: String, around guess: CGPoint, lookingFor description: String,
        rebuild: @escaping (CGRect) -> PendingMark?
    ) {
        guard let groundingService, let capture else { return }
        let generation = turnGeneration
        let slot = escalation.zoomSlot
        zoomPassesInFlight += 1
        Task { [weak self] in
            let zoomedRect = await groundingService.zoomPass(
                around: guess, lookingFor: description, capture: capture, slot: slot)
            guard let self, self.turnGeneration == generation else { return }
            self.zoomPassesInFlight = max(0, self.zoomPassesInFlight - 1)
            let isPending = self.pendingMarks[markIdentifier] != nil
            let isDrawn = self.registry.entries.contains { $0.identifier == markIdentifier }
            guard isPending || isDrawn else { return }
            guard let zoomedRect else {
                // A walkthrough step keeps its first guess: no circle at all left the user
                // with nothing to look at (D72); the next check corrects it if it's wrong.
                let isStepMark =
                    self.pendingMarks[markIdentifier]?.lifecycle == .stepBound
                    || self.registry.entries.contains {
                        $0.identifier == markIdentifier && $0.lifecycle == .stepBound
                    }
                if isStepMark && self.keepsStepMarks { return }
                self.escalation.recordFailure()
                self.pendingMarks.removeValue(forKey: markIdentifier)
                self.renderer.fade(
                    markIdentifiers: self.registry.clear(identifiers: [markIdentifier]),
                    seconds: AnnotationRenderer.cleanupFadeSeconds)
                self.askLearnerToCircle()
                return
            }
            guard
                let refined = rebuild(
                    capture.screenSpace.nativePixelRectToDisplayPoints(zoomedRect))
            else { return }
            if isPending {
                self.pendingMarks[markIdentifier] = refined
            } else if let request = refined.drawRequest {
                self.renderer.draw(request, usesPen: true)
                if refined.lifecycle == .stepBound { self.noteStepTarget(refined.targetRect) }
            }
        }
    }

    /// §6.2 (f): re-read the text under a fresh mark; move it if the text moved, drop it if the
    /// text is gone (and count a failure for §7.4 rule 5).
    private func verifyAfterDrawing(_ pendingMark: PendingMark) {
        guard let expectedText = pendingMark.expectedText,
            VerificationCheck.isVerifiable(expectedText), let targetRect = pendingMark.targetRect,
            let groundingService, let capture
        else { return }
        let generation = turnGeneration
        let screenSpace = capture.screenSpace
        let markIdentifier = pendingMark.markIdentifier
        let isStepMark = pendingMark.lifecycle == .stepBound
        let nativeRect = screenSpace.displayPointRectToNativePixels(targetRect)
        Task { [weak self] in
            let verdict = await groundingService.verify(
                expectedText: expectedText, markRectInNativePixels: nativeRect,
                screenSpace: screenSpace)
            guard let self, self.turnGeneration == generation,
                self.registry.entries.contains(where: { $0.identifier == markIdentifier })
            else { return }
            switch verdict {
            case .confirmed, .notVerifiable:
                break
            case .relocated(let relocatedNativeRect):
                let relocatedRect = screenSpace.nativePixelRectToDisplayPoints(relocatedNativeRect)
                // A walkthrough circle moves only a little (a scroll); a far move is another copy
                // of the same words ("Google Flights" twice on the page, D73).
                let moveDistance = hypot(
                    relocatedRect.midX - targetRect.midX, relocatedRect.midY - targetRect.midY)
                if isStepMark, moveDistance > Self.largestStepMarkRelocationPoints {
                    break
                }
                if let request = pendingMark.rebuild?(relocatedRect) {
                    self.renderer.draw(request, usesPen: true)
                    if isStepMark { self.noteStepTarget(relocatedRect) }
                }
            case .notFound where isStepMark:
                // Keep the circle; the next check corrects it if it's wrong (D73).
                break
            case .notFound:
                self.escalation.recordFailure()
                self.renderer.fade(
                    markIdentifiers: self.registry.clear(identifiers: [markIdentifier]),
                    seconds: AnnotationRenderer.cleanupFadeSeconds)
                self.askLearnerToCircle()
            }
        }
    }

    /// §5.10 "Can you circle it?", but never mid-answer: the owner heard it as Chalk giving up
    /// halfway when one equation couldn't be placed. It is asked once, after the answer, and
    /// only when nothing at all could be shown (D60).
    private func askLearnerToCircle() {
        guard !isTurnOver else { return }
        wantsToAskLearnerToCircle = true
    }

    private func askLearnerToCircleIfNothingWasShown() {
        guard wantsToAskLearnerToCircle, !hasShownSomethingThisTurn, !hasAskedToCircleThisTurn
        else { return }
        hasAskedToCircleThisTurn = true
        onAskLearnerToCircle?()
    }

    /// What to tell the zoom pass to look for when the script gave no label.
    private func describe(_ target: TargetDescriptor?) -> String {
        if case .text(let text, _, _) = target { return "the text \"\(text)\"" }
        return "what the learner asked about: \"\(learnerQuestion)\""
    }

    /// A `ring` is the small "here" mark; on anything bigger than it (a title, a field) it
    /// becomes an ellipse around the target, so it never sits as a dot in the middle (D50).
    static func ringDrawing(around rect: CGRect, seed: UInt64) -> RoughDrawing {
        let ringDiameter: CGFloat = 32
        guard max(rect.width, rect.height) > ringDiameter else {
            return RoughStrokeGenerator.ring(
                around: CGPoint(x: rect.midX, y: rect.midY), seed: seed)
        }
        return encircling(rect, seed: seed)
    }

    /// Targets this big get a hand-drawn box instead of an ellipse: an ellipse padded round a
    /// long equation line swept across half the screen (owner's hand test, D61).
    static let largestEllipseSize = CGSize(width: 360, height: 140)

    static func encircling(_ rect: CGRect, seed: UInt64) -> RoughDrawing {
        if rect.width > largestEllipseSize.width || rect.height > largestEllipseSize.height {
            return RoughStrokeGenerator.rectangle(around: rect, seed: seed)
        }
        return RoughStrokeGenerator.ellipse(around: rect, seed: seed)
    }

    /// Two targets are the same thing when most of the smaller one lies inside the other.
    static func isSameTarget(_ first: CGRect?, _ second: CGRect) -> Bool {
        guard let first else { return false }
        let overlap = first.intersection(second)
        guard !overlap.isNull else { return false }
        let smallerArea = min(first.width * first.height, second.width * second.height)
        return smallerArea > 0 && overlap.width * overlap.height / smallerArea > 0.5
    }

    private func downgraded(_ shape: AnnotationShape, _ markIdentifier: String) -> PendingMark? {
        // §6.4: an unresolvable target turns the drawing into speech-only.
        print("📜 Annotation: \(shape.rawValue) \(markIdentifier) target unresolved; speech-only")
        return nil
    }

    /// Ends an arrow at the target's edge instead of its centre, so the head doesn't cover it.
    static func pointShortOfEdge(from start: CGPoint, to end: CGPoint, rect: CGRect) -> CGPoint {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 1 else { return end }
        let shortenBy = min(length * 0.5, max(rect.width, rect.height) / 2 + 6)
        return CGPoint(
            x: end.x - (end.x - start.x) / length * shortenBy,
            y: end.y - (end.y - start.y) / length * shortenBy)
    }
}
