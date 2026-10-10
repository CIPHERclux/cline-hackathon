//
//  WhiteboardPanel.swift
//  Chalk
//
//  §4.2.9 whiteboard mode, demo cut: a rounded, non-activating board beside the work showing the
//  `numberline`, `math_steps` (§4.2.3, D02) and `geometry` (D59) figures. The buddy writes on it
//  (D57): the pen flies to each part and traces it while the part appears, one part after
//  another, like a teacher at a board. Parts are queued as the script reveals them on spoken
//  anchors (§4.2.4); whatever the script never revealed is written when the answer ends. The
//  board stays up across turns (`board` lifecycle, §4.2.2) until the learner closes it or a new
//  figure replaces it.
//

import AppKit
import ChalkCore
import Combine
import SwiftUI

@MainActor
final class WhiteboardModel: ObservableObject {
    enum Figure: Equatable {
        case numberLine(NumberLineSpec)
        case mathSteps(MathStepsSpec)
        case geometry(GeometrySpec)
    }

    /// What one written element is, which decides how long the pen takes over it.
    enum ElementKind {
        case text, axis, mark, interval, segment, angle
    }

    @Published private(set) var figure: Figure?
    /// 0…1 per element: how much of it has been written.
    @Published private(set) var elementProgress: [Double] = []
    /// Each element's pen path in the board's coordinate space, reported by the views.
    @Published var elementPenPaths: [Int: [CGPoint]] = [:]
    /// The element about to be written; a scrolling board brings it into view first.
    @Published var focusedElement: Int?
    private(set) var figureIdentifier: String?

    /// Elements in writing order. Math steps: the lines. Number line: the axis, then marks, then
    /// intervals. Geometry: the sides, then the angles.
    var elementCount: Int { elementProgress.count }

    var title: String? {
        switch figure {
        case .mathSteps(let spec): return spec.title
        case .geometry(let spec): return spec.title
        default: return nil
        }
    }

    func show(_ figure: Figure, identifier: String) {
        self.figure = figure
        figureIdentifier = identifier
        elementPenPaths = [:]
        focusedElement = nil
        let count: Int
        switch figure {
        case .mathSteps(let spec): count = spec.steps.count
        case .numberLine(let spec): count = 1 + spec.partCount
        case .geometry(let spec): count = spec.segments.count + spec.angles.count
        }
        elementProgress = Array(repeating: 0, count: count)
    }

    /// Script part (§4.2.4 reveal `part`) → the last element it covers.
    func elementIndex(forPart part: Int) -> Int {
        switch figure {
        case .mathSteps: return part
        case .numberLine: return part + 1
        // Part 0 is the whole shape; each later part is an angle.
        case .geometry(let spec): return spec.segments.count - 1 + part
        case nil: return part
        }
    }

    func kind(ofElement index: Int) -> ElementKind {
        switch figure {
        case .numberLine(let spec):
            if index == 0 { return .axis }
            return index <= spec.marks.count ? .mark : .interval
        case .geometry(let spec):
            return index < spec.segments.count ? .segment : .angle
        default:
            return .text
        }
    }

    func progress(ofElement index: Int) -> Double {
        index < elementProgress.count ? elementProgress[index] : 0
    }

    func setProgress(ofElement index: Int, to value: Double, animationSeconds: Double?) {
        guard index < elementProgress.count else { return }
        if let animationSeconds {
            withAnimation(.linear(duration: animationSeconds)) { elementProgress[index] = value }
        } else {
            elementProgress[index] = value
        }
    }

    func clear() {
        figure = nil
        figureIdentifier = nil
        elementProgress = []
        elementPenPaths = [:]
    }
}

/// The board never becomes key (it must not take focus from the user's app), so its views
/// take the first click directly: the close button works in one click. The walkthrough HUD and
/// the lasso chooser use it for the same reason.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WhiteboardPanel {
    static let panelSize = CGSize(width: 660, height: 440)
    /// A calm writing pace (D58), and a breath between parts.
    static let writingPointsPerSecond: CGFloat = 190
    static let drawingPointsPerSecond: CGFloat = 240
    static let pauseBetweenElementsSeconds = 0.25
    /// Time to scroll a line into view before the pen goes there.
    static let scrollSeconds = 0.3

    let model = WhiteboardModel()
    /// The learner closed the board: its `board` mark leaves the registry.
    var onClosed: ((_ figureIdentifier: String) -> Void)?
    /// Flies the pen along a path (display points, top-left) for `duration`; returns the flight
    /// time before it starts. Set by the AnnotationController (the renderer owns the pen).
    var movePen: ((_ path: CGPath, _ displayFrame: CGRect, _ duration: Double) -> Double)?
    /// The pen is writing, or has parts queued: speech waits for it (D72).
    var hasPendingWriting: Bool { isWriting || isWaitingForLayout || !writeQueue.isEmpty }

    private var panel: NSPanel?
    private var hostingView: NSView?
    private var closeObserver: NSObjectProtocol?
    private var writeQueue: [Int] = []
    private var isWriting = false
    private var isWaitingForLayout = false
    /// Bumped by every new figure and cleanup, so scheduled writing steps from before are dropped.
    private var writeGeneration = 0

    func show(_ figure: WhiteboardModel.Figure, identifier: String, onDisplay displayFrame: CGRect?)
    {
        let panel = self.panel ?? makePanel()
        writeGeneration += 1
        writeQueue = []
        isWriting = false
        isWaitingForLayout = false
        model.show(figure, identifier: identifier)
        if !panel.isVisible {
            // Right-hand side of the display the turn is about, vertically centred.
            let display = displayFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let origin = CGPoint(
                x: display.maxX - Self.panelSize.width - 40,
                y: display.midY - Self.panelSize.height / 2)
            panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: false)
        }
        panel.orderFrontRegardless()
        // Part 0 comes with the figure.
        enqueueWriting(upToElement: model.elementIndex(forPart: 0))
    }

    /// Writes up to script part `part`; nil writes the next one.
    func reveal(part: Int?, identifier: String?) {
        guard model.figure != nil, identifier == nil || identifier == model.figureIdentifier else {
            return
        }
        let nextUnwritten = (0..<model.elementCount).first {
            model.progress(ofElement: $0) == 0 && !writeQueue.contains($0)
        }
        guard let target = part.map({ model.elementIndex(forPart: $0) }) ?? nextUnwritten else {
            return
        }
        enqueueWriting(upToElement: target)
    }

    func revealAll() {
        guard model.figure != nil else { return }
        enqueueWriting(upToElement: model.elementCount - 1)
    }

    /// Cleanup (Esc, the talk key): whatever is queued appears at once, without the pen.
    func finishWritingInstantly() {
        writeGeneration += 1
        for element in writeQueue {
            model.setProgress(ofElement: element, to: 1, animationSeconds: nil)
        }
        writeQueue = []
        isWriting = false
        isWaitingForLayout = false
    }

    func close() { panel?.close() }

    // MARK: - Writing

    private func enqueueWriting(upToElement lastElement: Int) {
        let last = min(lastElement, model.elementCount - 1)
        guard last >= 0 else { return }
        for element in 0...last
        where model.progress(ofElement: element) == 0 && !writeQueue.contains(element) {
            writeQueue.append(element)
        }
        writeNext()
    }

    private func writeNext(layoutRetries: Int = 0) {
        guard !isWriting, !isWaitingForLayout || layoutRetries > 0, let element = writeQueue.first
        else { return }
        let generation = writeGeneration
        // Math steps scroll: bring the line into view, let the scroll settle, then write.
        if model.kind(ofElement: element) == .text, model.focusedElement != element {
            model.focusedElement = element
            isWaitingForLayout = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSeconds + 0.1) {
                [weak self] in
                guard let self, self.writeGeneration == generation else { return }
                self.writeNext(layoutRetries: layoutRetries + 1)
            }
            return
        }
        guard let boardPoints = model.elementPenPaths[element], boardPoints.count >= 2,
            let displayFrame = panel?.screen?.frame,
            let path = displayPath(fromBoard: boardPoints, displayFrame: displayFrame)
        else {
            // The views report their paths after the first layout: wait a moment, then give up on
            // the pen and just show the part.
            if layoutRetries < 10 {
                isWaitingForLayout = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.writeGeneration == generation else { return }
                    self.writeNext(layoutRetries: layoutRetries + 1)
                }
                return
            }
            isWaitingForLayout = false
            writeQueue.removeFirst()
            model.setProgress(ofElement: element, to: 1, animationSeconds: 0.3)
            writeNext()
            return
        }
        isWaitingForLayout = false
        writeQueue.removeFirst()
        isWriting = true
        let duration = writingSeconds(forElement: element, boardPoints: boardPoints)
        let approach = movePen?(path, displayFrame, duration) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + approach) { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.model.setProgress(ofElement: element, to: 1, animationSeconds: duration)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + approach + duration + Self.pauseBetweenElementsSeconds
        ) { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.isWriting = false
            self.writeNext()
        }
    }

    private func writingSeconds(forElement element: Int, boardPoints: [CGPoint]) -> Double {
        let length = zip(boardPoints, boardPoints.dropFirst()).reduce(CGFloat(0)) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
        switch model.kind(ofElement: element) {
        case .text:
            let span = (boardPoints.last?.x ?? 0) - (boardPoints.first?.x ?? 0)
            return min(2.2, max(0.6, Double(span / Self.writingPointsPerSecond)))
        case .axis: return 1.1
        case .mark: return 0.6
        case .interval: return min(1.0, max(0.5, Double(length / 300)))
        case .segment: return min(1.4, max(0.5, Double(length / Self.drawingPointsPerSecond)))
        case .angle: return 0.5
        }
    }

    /// Board points → a path in the display's points (top-left origin).
    private func displayPath(fromBoard points: [CGPoint], displayFrame: CGRect) -> CGPath? {
        let displayPoints = points.compactMap {
            displayPoint(fromBoard: $0, displayFrame: displayFrame)
        }
        guard let first = displayPoints.first, displayPoints.count == points.count else {
            return nil
        }
        let path = CGMutablePath()
        path.move(to: first)
        for point in displayPoints.dropFirst() { path.addLine(to: point) }
        return path
    }

    /// Board space (the hosting view, top-left origin) → the display's points, top-left origin.
    private func displayPoint(fromBoard point: CGPoint, displayFrame: CGRect) -> CGPoint? {
        guard let hostingView, let window = hostingView.window else { return nil }
        let viewPoint =
            hostingView.isFlipped
            ? point : CGPoint(x: point.x, y: hostingView.bounds.height - point.y)
        let screenPoint = window.convertPoint(toScreen: hostingView.convert(viewPoint, to: nil))
        return CGPoint(x: screenPoint.x - displayFrame.minX, y: displayFrame.maxY - screenPoint.y)
    }

    private func makePanel() -> NSPanel {
        // Borderless with rounded corners drawn by the board itself; dragged by its background.
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = ChalkOverlaySharing.current
        panel.minSize = CGSize(width: 420, height: 300)
        let hostingView = FirstClickHostingView(
            rootView: WhiteboardView(model: model, onClose: { [weak panel] in panel?.close() }))
        panel.contentView = hostingView
        self.hostingView = hostingView
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishWritingInstantly()
                if let identifier = self.model.figureIdentifier { self.onClosed?(identifier) }
                self.model.clear()
            }
        }
        self.panel = panel
        return panel
    }
}
