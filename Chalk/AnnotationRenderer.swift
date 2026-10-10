//
//  AnnotationRenderer.swift
//  Chalk
//
//  Draws annotation marks on the real screen (§6.5): one borderless, click-through, non-key
//  window per display (separate from the cursor overlay), a layer-backed canvas in it, and one
//  CALayer group per mark. Strokes animate `strokeEnd` with Core Animation, which runs on the
//  render server: no timers or display links in the app (P-IDLECPU). No full-screen fill
//  (P-BLACKCAP); `sharingType = .none` keeps marks out of other apps' captures (§6.6), and our own
//  model screenshots exclude every window of this app.
//

import AppKit
import ChalkCore
import QuartzCore
import SwiftUI
import os

/// One mark to draw, already resolved to overlay-local points (top-left origin, on one display).
struct AnnotationDrawRequest {
    let markIdentifier: String
    let drawing: RoughDrawing
    let role: AnnotationColorRole
    let label: String?
    /// Where a label chip goes (overlay-local points), next to its target.
    let labelAnchor: CGPoint?
    /// §5.5 z-order: highlights < boxes and ellipses < arrows < badges and labels.
    let zOrder: CGFloat
    let displayFrameInAppKitGlobal: CGRect
}

@MainActor
final class AnnotationRenderer {
    static let strokeWidth: CGFloat = 2.5
    private static let log = Logger(subsystem: "com.chalk.app", category: "sync")
    /// §5.5: 250–600 ms, scaled by length.
    /// §5.5 says 250–600 ms; slowed so a stroke can be followed (owner, D58).
    static let minimumDrawSeconds = 0.5
    static let maximumDrawSeconds = 1.1
    static let fadeOutSeconds = 0.4
    /// §4.2.2 rule 3: cleanup triggers clear within 150 ms.
    static let cleanupFadeSeconds = 0.12

    /// The pen's flight to a stroke: quick, so ink follows the anchor word closely (D50).
    static let minimumPenApproachSeconds = 0.22
    static let maximumPenApproachSeconds = 0.45
    static let penApproachPointsPerSecond: CGFloat = 1800
    /// How long the pen rests on the last mark before flying home, and the flight home.
    static let penHoldSeconds = 0.6
    static let penReturnSeconds = 0.25

    private var canvasByDisplayFrame: [CGRect: AnnotationCanvasView] = [:]
    private var windowByDisplayFrame: [CGRect: NSWindow] = [:]
    private var markLayers: [String: CALayer] = [:]
    private var displayFrameByMark: [String: CGRect] = [:]
    /// Hidden for a system screenshot (§6.6, P-SCRNSHOT); marks keep animating underneath.
    private var isHiddenForScreenshot = false

    /// The pen (D50): the Chalk beacon flies to each mark and traces it while the ink
    /// appears, then flies back to the buddy's spot. Core Animation only; one work item for the
    /// trip home.
    var onPenActiveChanged: ((Bool) -> Void)?
    private var penLayerByDisplayFrame: [CGRect: CAShapeLayer] = [:]
    private var activePenDisplayFrame: CGRect?
    private var penHomeWorkItem: DispatchWorkItem?
    /// Bumped on every pen move, so a finished trip home can't hide a pen that started again.
    private var penGeneration = 0

    var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Draws one mark. With `usesPen`, the pen flies there first and the strokes start when it
    /// arrives; returns that flight's length in seconds (0 without the pen).
    @discardableResult
    func draw(_ request: AnnotationDrawRequest, usesPen: Bool) -> Double {
        removeImmediately(markIdentifiers: [request.markIdentifier])
        let canvas = canvas(forDisplayFrame: request.displayFrameInAppKitGlobal)
        let group = CALayer()
        group.frame = canvas.bounds
        group.zPosition = request.zOrder
        group.name = request.markIdentifier
        // A soft dark halo keeps strokes readable on both light and dark backgrounds (§5.6).
        group.shadowColor = NSColor.black.cgColor
        group.shadowOpacity = 0.55
        group.shadowRadius = 1.5
        group.shadowOffset = .zero

        // Paths come in top-left (overlay-local) points; the canvas is unflipped so text layers
        // render upright, so geometry is flipped here instead.
        let flip = CGAffineTransform(translationX: 0, y: canvas.bounds.height).scaledBy(x: 1, y: -1)
        func flipped(_ path: CGPath) -> CGPath { path.copy(using: [flip]) ?? path }

        let drawSeconds = min(
            Self.maximumDrawSeconds,
            max(Self.minimumDrawSeconds, Double(request.drawing.approximateLength) / 550))
        let color = request.role.color.cgColor

        var penApproachSeconds = 0.0
        if usesPen, !reducesMotion, let tracePath = Self.penTracePath(for: request.drawing) {
            penApproachSeconds = movePen(
                on: canvas, displayFrame: request.displayFrameInAppKitGlobal,
                tracing: flipped(tracePath), accents: request.drawing.accents.first.map(flipped),
                drawSeconds: drawSeconds)
        }

        if let fill = request.drawing.fill {
            let fillLayer = CAShapeLayer()
            fillLayer.path = flipped(fill)
            fillLayer.fillColor = request.role.color.withAlphaComponent(0.32).cgColor
            fillLayer.strokeColor = nil
            group.addSublayer(fillLayer)
            animateAppearance(
                of: fillLayer, duration: reducesMotion ? 0.15 : drawSeconds,
                delay: penApproachSeconds)
        }
        for (index, strokePath) in request.drawing.strokes.enumerated() {
            let strokeLayer = makeStrokeLayer(path: flipped(strokePath), color: color)
            group.addSublayer(strokeLayer)
            // The second pass of a double stroke trails the first slightly, like a re-traced line.
            let delay = penApproachSeconds + Double(index) * drawSeconds * 0.25
            if reducesMotion {
                animateAppearance(of: strokeLayer, duration: 0.15, delay: 0)
            } else {
                animateStroke(of: strokeLayer, duration: drawSeconds, delay: delay)
            }
        }
        for accentPath in request.drawing.accents {
            let accentLayer = makeStrokeLayer(path: flipped(accentPath), color: color)
            group.addSublayer(accentLayer)
            // §5.5: arrowheads pop in 80 ms after the shaft; with the pen they are drawn by it.
            if penApproachSeconds > 0 {
                animateStroke(
                    of: accentLayer, duration: Self.penAccentSeconds,
                    delay: penApproachSeconds + drawSeconds + 0.08)
            } else {
                animateAppearance(
                    of: accentLayer, duration: 0.08, delay: reducesMotion ? 0 : drawSeconds + 0.08)
            }
        }
        if let label = request.label, !label.isEmpty, let labelAnchor = request.labelAnchor {
            let chip = makeLabelChip(
                text: label, color: request.role.color, anchor: labelAnchor,
                canvasBounds: canvas.bounds)
            group.addSublayer(chip)
            animateAppearance(
                of: chip, duration: 0.15,
                delay: reducesMotion ? 0 : penApproachSeconds + drawSeconds * 0.6)
        }

        canvas.layer?.addSublayer(group)
        markLayers[request.markIdentifier] = group
        displayFrameByMark[request.markIdentifier] = request.displayFrameInAppKitGlobal
        windowByDisplayFrame[request.displayFrameInAppKitGlobal]?.orderFrontRegardless()
        if isHiddenForScreenshot {
            // Owner saw no marks once; this says when a ⇧⌘3/4/5 in the last 10 s hid them (§6.6).
            Self.log.notice(
                "🖍️ \(request.markIdentifier, privacy: .public) drawn while hidden for a screenshot")
        }
        return penApproachSeconds
    }

    /// Fades marks out (§5.5: 400 ms easeIn), then removes them.
    func fade(markIdentifiers: [String], seconds: Double? = nil) {
        let seconds = seconds ?? Self.fadeOutSeconds
        for identifier in markIdentifiers {
            guard let group = markLayers.removeValue(forKey: identifier) else { continue }
            displayFrameByMark.removeValue(forKey: identifier)
            CATransaction.begin()
            CATransaction.setCompletionBlock { group.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = group.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = seconds
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.opacity = 0
            group.add(fade, forKey: "fadeOut")
            CATransaction.commit()
        }
        hideIdleWindowsSoon(after: seconds)
    }

    func removeImmediately(markIdentifiers: [String]) {
        for identifier in markIdentifiers {
            markLayers.removeValue(forKey: identifier)?.removeFromSuperlayer()
            displayFrameByMark.removeValue(forKey: identifier)
        }
    }

    var liveMarkIdentifiers: [String] { Array(markLayers.keys) }

    func setHiddenForScreenshot(_ hidden: Bool) {
        isHiddenForScreenshot = hidden
        for window in windowByDisplayFrame.values { window.alphaValue = hidden ? 0 : 1 }
    }

    /// Presenter mode changed (D53).
    func applySharingType() {
        for window in windowByDisplayFrame.values {
            window.sharingType = ChalkOverlaySharing.current
        }
    }

    /// Displays changed (P-DISPLAYS): windows are keyed by display frame, so they are dropped
    /// and rebuilt on the next draw. Callers clear the marks first.
    func discardWindows() {
        penHomeWorkItem?.cancel()
        penHomeWorkItem = nil
        if activePenDisplayFrame != nil {
            activePenDisplayFrame = nil
            onPenActiveChanged?(false)
        }
        for window in windowByDisplayFrame.values { window.orderOut(nil) }
        windowByDisplayFrame.removeAll()
        canvasByDisplayFrame.removeAll()
        penLayerByDisplayFrame.removeAll()
        markLayers.removeAll()
        displayFrameByMark.removeAll()
    }

    // MARK: - Windows

    private func canvas(forDisplayFrame displayFrame: CGRect) -> AnnotationCanvasView {
        if let canvas = canvasByDisplayFrame[displayFrame] { return canvas }
        let window = NSWindow(
            contentRect: displayFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Same level as the cursor overlay until spike S6 decides (D12).
        window.level = ChalkOverlayLevel.current
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.sharingType = ChalkOverlaySharing.current
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.alphaValue = isHiddenForScreenshot ? 0 : 1
        window.setFrame(displayFrame, display: false)
        let canvas = AnnotationCanvasView(frame: CGRect(origin: .zero, size: displayFrame.size))
        window.contentView = canvas
        canvasByDisplayFrame[displayFrame] = canvas
        windowByDisplayFrame[displayFrame] = window
        return canvas
    }

    /// Windows with no live marks and no pen leave the screen once their fades finish, so an
    /// idle Chalk has no windows to composite. Decided from the registry of live marks, not the
    /// layer tree, so a late fade completion can't keep a window up.
    private func hideIdleWindowsSoon(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            guard let self else { return }
            let busyDisplayFrames = Set(self.displayFrameByMark.values)
            for (displayFrame, window) in self.windowByDisplayFrame
            where !busyDisplayFrames.contains(displayFrame)
                && self.activePenDisplayFrame != displayFrame
            {
                window.orderOut(nil)
            }
        }
    }

    // MARK: - Pen (D50)

    static let penAccentSeconds = 0.12

    /// The pen follows the first stroke (a double-pass ellipse's second pass trails it); a
    /// highlighter fill is swept left to right through its middle.
    static func penTracePath(for drawing: RoughDrawing) -> CGPath? {
        if let firstStroke = drawing.strokes.first { return firstStroke }
        guard let fill = drawing.fill else { return nil }
        let band = fill.boundingBoxOfPath
        let sweep = CGMutablePath()
        sweep.move(to: CGPoint(x: band.minX, y: band.midY))
        sweep.addLine(to: CGPoint(x: band.maxX, y: band.midY))
        return sweep
    }

    /// Where the beacon centre is (canvas points), or nil when the mouse is on another
    /// display.
    private func penHome(inDisplayFrame displayFrame: CGRect) -> CGPoint? {
        let mouseLocation = NSEvent.mouseLocation
        guard displayFrame.contains(mouseLocation) else { return nil }
        return CGPoint(
            x: mouseLocation.x + Self.buddyTipOffsetFromMouse.x - displayFrame.minX,
            y: mouseLocation.y + Self.buddyTipOffsetFromMouse.y - displayFrame.minY)
    }

    /// Beacon centre relative to the mouse, AppKit points (y up), matching the idle overlay.
    static let buddyTipOffsetFromMouse = CGPoint(x: 35, y: -25)

    /// Flies the pen to the start of `tracing`, traces it (then the arrowhead), and schedules the
    /// trip home. Returns the flight time, which delays the ink.
    private func movePen(
        on canvas: AnnotationCanvasView, displayFrame: CGRect, tracing tracePath: CGPath,
        accents accentPath: CGPath?, drawSeconds: Double,
        traceTiming: CAMediaTimingFunctionName = .easeOut
    ) -> Double {
        guard let traceStart = Self.firstPoint(of: tracePath) else { return 0 }
        penHomeWorkItem?.cancel()
        penGeneration += 1
        // One pen at a time: a pen still on another display disappears.
        if let activePenDisplayFrame, activePenDisplayFrame != displayFrame {
            setOpacityWithoutAnimation(penLayerByDisplayFrame[activePenDisplayFrame], 0)
        }
        let pen = penLayer(on: canvas, displayFrame: displayFrame)
        let penIsAlreadyHere = activePenDisplayFrame == displayFrame && pen.opacity > 0
        let startPoint =
            penIsAlreadyHere
            ? (pen.presentation() ?? pen).position
            : (penHome(inDisplayFrame: displayFrame) ?? traceStart)

        let distance = hypot(traceStart.x - startPoint.x, traceStart.y - startPoint.y)
        let approachSeconds =
            distance < 1
            ? 0
            : min(
                Self.maximumPenApproachSeconds,
                max(
                    Self.minimumPenApproachSeconds,
                    Double(distance / Self.penApproachPointsPerSecond)))
        var animations: [CAAnimation] = []
        if approachSeconds > 0 {
            // A slight arc, like the v1 pointing flight.
            let approach = CAKeyframeAnimation(keyPath: "position")
            let arc = CGMutablePath()
            arc.move(to: startPoint)
            let middle = CGPoint(
                x: (startPoint.x + traceStart.x) / 2, y: (startPoint.y + traceStart.y) / 2)
            let lift = min(distance * 0.2, 60)
            arc.addQuadCurve(
                to: traceStart,
                control: CGPoint(
                    x: middle.x - (traceStart.y - startPoint.y) / distance * lift,
                    y: middle.y + (traceStart.x - startPoint.x) / distance * lift))
            approach.path = arc
            approach.duration = approachSeconds
            approach.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animations.append(approach)
        }
        let trace = CAKeyframeAnimation(keyPath: "position")
        trace.path = tracePath
        trace.calculationMode = .paced
        trace.beginTime = approachSeconds
        trace.duration = drawSeconds
        // Same easing as the stroke's strokeEnd, so the tip stays on the growing line.
        trace.timingFunction = CAMediaTimingFunction(name: traceTiming)
        // Holds the stroke's end through the pause before the arrowhead (later animations in
        // the group win while they run).
        trace.fillMode = .forwards
        animations.append(trace)
        var endPoint = tracePath.currentPoint
        var totalSeconds = approachSeconds + drawSeconds
        if let accentPath {
            let accent = CAKeyframeAnimation(keyPath: "position")
            accent.path = accentPath
            accent.calculationMode = .paced
            accent.beginTime = approachSeconds + drawSeconds + 0.08
            accent.duration = Self.penAccentSeconds
            animations.append(accent)
            endPoint = accentPath.currentPoint
            totalSeconds = accent.beginTime + accent.duration
        }
        let flight = CAAnimationGroup()
        flight.animations = animations
        flight.duration = totalSeconds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pen.removeAnimation(forKey: "home")
        pen.position = endPoint
        pen.opacity = 1
        pen.add(flight, forKey: "pen")
        CATransaction.commit()

        if !penIsAlreadyHere {
            activePenDisplayFrame = displayFrame
            onPenActiveChanged?(true)
        }
        let workItem = DispatchWorkItem { [weak self] in self?.sendPenHome() }
        penHomeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + totalSeconds + Self.penHoldSeconds, execute: workItem)
        return approachSeconds
    }

    /// The pen without ink of its own (S10 whiteboard): it flies to `path` (display points,
    /// top-left origin) and follows it at a steady speed while the board reveals what it
    /// "writes". Returns the flight time before the writing starts (0 with Reduce Motion).
    @discardableResult
    func movePenAlong(_ path: CGPath, displayFrame: CGRect, durationSeconds: Double) -> Double {
        guard !reducesMotion else { return 0 }
        let canvas = canvas(forDisplayFrame: displayFrame)
        windowByDisplayFrame[displayFrame]?.orderFrontRegardless()
        let flip = CGAffineTransform(translationX: 0, y: canvas.bounds.height).scaledBy(x: 1, y: -1)
        guard let flippedPath = path.copy(using: [flip]) else { return 0 }
        return movePen(
            on: canvas, displayFrame: displayFrame, tracing: flippedPath, accents: nil,
            drawSeconds: durationSeconds, traceTiming: .linear)
    }

    /// The pen flies back to the buddy's spot (or fades if the mouse is on another display) and
    /// the buddy takes over again. `animated: false` is for cleanup triggers.
    func sendPenHome(animated: Bool = true) {
        penHomeWorkItem?.cancel()
        penHomeWorkItem = nil
        guard let displayFrame = activePenDisplayFrame,
            let pen = penLayerByDisplayFrame[displayFrame]
        else { return }
        penGeneration += 1
        let generation = penGeneration
        let finish = { [weak self] in
            guard let self, self.penGeneration == generation else { return }
            self.setOpacityWithoutAnimation(pen, 0)
            self.activePenDisplayFrame = nil
            self.onPenActiveChanged?(false)
            self.hideIdleWindowsSoon(after: 0)
        }
        let currentPosition = (pen.presentation() ?? pen).position
        guard animated, !reducesMotion else {
            pen.removeAllAnimations()
            finish()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        pen.removeAnimation(forKey: "pen")
        if let home = penHome(inDisplayFrame: displayFrame) {
            let flightHome = CABasicAnimation(keyPath: "position")
            flightHome.fromValue = NSValue(point: currentPosition)
            flightHome.toValue = NSValue(point: home)
            flightHome.duration = Self.penReturnSeconds
            flightHome.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pen.position = home
            pen.add(flightHome, forKey: "home")
        } else {
            pen.position = currentPosition
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = Self.penReturnSeconds
            pen.add(fadeOut, forKey: "home")
        }
        CATransaction.commit()
    }

    /// The same four-point beacon as the idle overlay, centred on the active stroke (§5.5).
    private func penLayer(on canvas: AnnotationCanvasView, displayFrame: CGRect) -> CAShapeLayer {
        if let pen = penLayerByDisplayFrame[displayFrame] { return pen }
        let side: CGFloat = 22
        let centre = CGPoint(x: side / 2, y: side / 2)
        let pen = CAShapeLayer()
        pen.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        pen.path = ChalkBeacon().path(in: pen.bounds).cgPath
        pen.fillColor = AnnotationColorRole.focus.color.cgColor
        pen.strokeColor = NSColor(DS.Colors.ink).cgColor
        pen.lineWidth = 1
        pen.shadowColor = NSColor(DS.Colors.ink).cgColor
        pen.shadowOpacity = 0.35
        pen.shadowRadius = 3
        pen.shadowOffset = .zero
        pen.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let core = CAShapeLayer()
        core.path = CGPath(
            ellipseIn: CGRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3),
            transform: nil)
        core.fillColor = NSColor(DS.Colors.paper).cgColor
        pen.addSublayer(core)
        pen.zPosition = 100
        pen.opacity = 0
        canvas.layer?.addSublayer(pen)
        penLayerByDisplayFrame[displayFrame] = pen
        return pen
    }

    private func setOpacityWithoutAnimation(_ layer: CALayer?, _ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = opacity
        CATransaction.commit()
    }

    private static func firstPoint(of path: CGPath) -> CGPoint? {
        var firstPoint: CGPoint?
        path.applyWithBlock { elementPointer in
            if firstPoint == nil, elementPointer.pointee.type == .moveToPoint {
                firstPoint = elementPointer.pointee.points[0]
            }
        }
        return firstPoint
    }

    // MARK: - Layers and animation

    private func makeStrokeLayer(path: CGPath, color: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.strokeColor = color
        layer.fillColor = nil
        layer.lineWidth = Self.strokeWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }

    private func animateStroke(of layer: CAShapeLayer, duration: Double, delay: Double) {
        layer.strokeEnd = 1
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "draw")
    }

    private func animateAppearance(of layer: CALayer, duration: Double, delay: Double) {
        layer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        layer.add(animation, forKey: "appear")
    }

    /// §5.5 label: editorial paper card with a semantic ink border, max 6 words.
    private func makeLabelChip(text: String, color: NSColor, anchor: CGPoint, canvasBounds: CGRect)
        -> CALayer
    {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributed = NSAttributedString(
            string: words, attributes: [.font: font, .foregroundColor: NSColor(DS.Colors.ink)])
        let textSize = attributed.size()
        let chipSize = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 8)
        // Right of the anchor, kept on screen.
        var origin = CGPoint(x: anchor.x + 6, y: anchor.y - chipSize.height / 2)
        origin.x = min(max(origin.x, 8), canvasBounds.width - chipSize.width - 8)
        origin.y = min(max(origin.y, 8), canvasBounds.height - chipSize.height - 8)

        let chip = CALayer()
        // Top-left placement → the unflipped canvas.
        chip.frame = CGRect(
            x: origin.x, y: canvasBounds.height - origin.y - chipSize.height, width: chipSize.width,
            height: chipSize.height)
        chip.backgroundColor = NSColor(DS.Colors.paper).cgColor
        chip.cornerRadius = 10
        chip.borderColor = color.cgColor
        chip.borderWidth = 1.5
        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.frame = CGRect(
            x: 8, y: 4, width: ceil(textSize.width), height: ceil(textSize.height))
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        chip.addSublayer(textLayer)
        return chip
    }
}

/// The per-display canvas. Unflipped (text layers render upright); the renderer flips geometry.
final class AnnotationCanvasView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    // Click-through at the view level too (§3.5): the window already ignores mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
