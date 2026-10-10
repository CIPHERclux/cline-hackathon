//
//  DrawChordPanel.swift
//  Chalk
//
//  §4.2.5 learner → buddy drawing: while the talk chord (⌃⌥) is held, a transparent panel on the
//  active display takes the mouse so the learner can circle or mark something, leaving a dusty-rose
//  paint trail. It is the one exception to the click-through rule (§3.5), and only for as long as
//  the learner holds the chord: the panel leaves the screen on release.
//

import AppKit
import ChalkCore
import QuartzCore
import SwiftUI

@MainActor
final class DrawChordPanel {
    private var panel: NSPanel?
    private var canvas: DrawChordCanvasView?
    private var displayFrame: CGRect?

    /// The chord went down: take the mouse on the display under it.
    func begin(onScreen screen: NSScreen) {
        if panel == nil || displayFrame != screen.frame {
            panel?.orderOut(nil)
            makePanel(for: screen)
        }
        canvas?.clearStrokes()
        panel?.orderFrontRegardless()
    }

    /// The chord came up: the panel leaves (click-through again) and hands back what was drawn,
    /// in display points (top-left origin), or nil when nothing was.
    func end() -> (strokes: [[CGPoint]], displayFrame: CGRect)? {
        panel?.orderOut(nil)
        guard let canvas, let displayFrame else { return nil }
        let strokes = canvas.strokes.filter { $0.count > 1 }
        canvas.clearStrokes()
        return strokes.isEmpty ? nil : (strokes, displayFrame)
    }

    private func makePanel(for screen: NSScreen) {
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Set explicitly: a transparent window then still receives clicks and drags in its
        // clear areas, so no full-screen fill is needed (P-BLACKCAP).
        panel.ignoresMouseEvents = false
        panel.level = ChalkOverlayLevel.current
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = ChalkOverlaySharing.current
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setFrame(screen.frame, display: false)
        let canvas = DrawChordCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = canvas
        self.panel = panel
        self.canvas = canvas
        displayFrame = screen.frame
    }
}

/// Collects the strokes and draws the paint trail. Strokes are stored as display points with a
/// top-left origin (ScreenSpace's convention); the view stays unflipped and the trail is flipped
/// explicitly, as in AnnotationCanvasView, so the layer geometry is never ambiguous.
final class DrawChordCanvasView: NSView {
    private(set) var strokes: [[CGPoint]] = []
    private let trailLayer = CAShapeLayer()
    /// A restrained plum halo keeps the dusty-rose trail visible on light or dark apps.
    private let glowLayer = CAShapeLayer()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // §5.6: the live learner trail uses the same dusty rose as exported learner marks.
        let learnerColor = AnnotationColorRole.learner.color
        for (shapeLayer, shadowRadius, shadowOpacity) in [
            (glowLayer, CGFloat(4), Float(0.25)), (trailLayer, CGFloat(1.5), Float(0.5)),
        ] {
            shapeLayer.strokeColor = learnerColor.cgColor
            shapeLayer.fillColor = nil
            shapeLayer.lineWidth = 3
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            shapeLayer.shadowColor = NSColor(DS.Colors.ink).cgColor
            shapeLayer.shadowOpacity = shadowOpacity
            shapeLayer.shadowRadius = shadowRadius
            shapeLayer.shadowOffset = .zero
            shapeLayer.frame = bounds
            layer?.addSublayer(shapeLayer)
        }
    }

    required init?(coder: NSCoder) { nil }

    func clearStrokes() {
        strokes = []
        redraw()
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([topLeftPoint(of: event)])
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(topLeftPoint(of: event))
        redraw()
    }

    private func topLeftPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func redraw() {
        // Mouse samples joined with quadratic curves through their midpoints: a smooth stroke
        // instead of visible straight segments.
        let path = CGMutablePath()
        for stroke in strokes {
            let points = stroke.map { CGPoint(x: $0.x, y: bounds.height - $0.y) }
            guard let first = points.first else { continue }
            path.move(to: first)
            guard points.count > 2 else {
                if let last = points.last { path.addLine(to: last) }
                continue
            }
            for index in 1..<(points.count - 1) {
                let midpoint = CGPoint(
                    x: (points[index].x + points[index + 1].x) / 2,
                    y: (points[index].y + points[index + 1].y) / 2)
                path.addQuadCurve(to: midpoint, control: points[index])
            }
            path.addLine(to: points[points.count - 1])
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailLayer.path = path
        glowLayer.path = path
        CATransaction.commit()
    }
}
