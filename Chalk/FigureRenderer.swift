//
//  FigureRenderer.swift
//  Chalk
//
//  The whiteboard's look and its figures (§4.2.3, §4.2.9). A rounded slate board with a faint
//  grid, a chalk-tray ledge and a header; math steps in a chalk hand aligned on "=", numbered,
//  with what changed since the line before in the `explain` colour (§5.6); a number line; and
//  geometry (D59). Every element reports the path the buddy's pen traces while writing it (D57),
//  in the board's coordinate space; the element is revealed over the same time. Plain Unicode
//  text, no LaTeX (D25). Nothing animates while the board is still (P-IDLECPU).
//

import AppKit
import ChalkCore
import Combine
import SwiftUI

struct WhiteboardView: View {
    @ObservedObject var model: WhiteboardModel
    let onClose: () -> Void

    static let chalkColor = DS.Colors.ink
    static let highlightColor = DS.Colors.accent
    static let markColor = Color(hex: "#695084")
    static let slateTop = DS.Colors.paper
    static let slateBottom = DS.Colors.background
    static let cornerRadius: CGFloat = 22
    static let coordinateSpaceName = "board"

    /// Chalkboard SE ships with macOS: a hand-lettered look for the board.
    static func chalkFont(size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "ChalkboardSE-Bold" : "ChalkboardSE-Regular", size: size)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            boardSurface
            VStack(alignment: .leading, spacing: 0) {
                header
                figure
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                chalkLedge
            }
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(ElementPenPathsKey.self) { paths in
            MainActor.assumeIsolated { model.elementPenPaths = paths }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .ignoresSafeArea()
    }

    private var boardSurface: some View {
        ZStack {
            LinearGradient(
                colors: [Self.slateTop, Self.slateBottom], startPoint: .top, endPoint: .bottom)
            // A faint dot grid, like a ruled board.
            Canvas { context, size in
                let spacing: CGFloat = 26
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)),
                            with: .color(DS.Colors.ink.opacity(0.09)))
                        x += spacing
                    }
                    y += spacing
                }
            }
            // Chalk dust: a soft light from the top.
            RadialGradient(
                colors: [Color.white.opacity(0.06), .clear], center: .top, startRadius: 10,
                endRadius: 420)
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Self.chalkColor.opacity(0.55))
            Text(model.title ?? "Working notes")
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundColor(Self.chalkColor.opacity(0.8))
                .lineLimit(1)
            Spacer()
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var figure: some View {
        switch model.figure {
        case .numberLine(let spec):
            NumberLineFigureView(spec: spec, model: model).padding(.horizontal, 18)
        case .mathSteps(let spec):
            MathStepsFigureView(spec: spec, model: model)
                .padding(.horizontal, 28)
                .padding(.top, 12)
        case .geometry(let spec):
            GeometryFigureView(spec: spec, model: model).padding(.horizontal, 12)
        case nil:
            Color.clear
        }
    }

    /// The board's chalk tray.
    private var chalkLedge: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [DS.Colors.apricot, DS.Colors.lavender],
                    startPoint: .top, endPoint: .bottom)
            )
            .frame(height: 5)
            .padding(.horizontal, 36)
            .padding(.bottom, 12)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DS.Colors.ink.opacity(isHovered ? 0.95 : 0.6))
            .frame(width: 22, height: 22)
            .background(Circle().fill(DS.Colors.ink.opacity(isHovered ? 0.12 : 0.06)))
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: action)
            .pointerCursor()
    }
}

/// Each written element's pen path in the board's coordinate space (top-left origin).
struct ElementPenPathsKey: PreferenceKey {
    static let defaultValue: [Int: [CGPoint]] = [:]
    static func reduce(value: inout [Int: [CGPoint]], nextValue: () -> [Int: [CGPoint]]) {
        value.merge(nextValue()) { _, new in new }
    }
}

enum PenPaths {
    /// A handwriting wiggle along a line of text.
    static func writing(across frame: CGRect) -> [CGPoint] {
        let amplitude = frame.height * 0.18
        var points: [CGPoint] = []
        var x = frame.minX
        var isUp = true
        while x < frame.maxX {
            points.append(CGPoint(x: x, y: frame.midY + (isUp ? -amplitude : amplitude)))
            x += 12
            isUp.toggle()
        }
        points.append(CGPoint(x: frame.maxX, y: frame.midY))
        return points
    }

    static func loop(around center: CGPoint, radius: CGFloat) -> [CGPoint] {
        (0...12).map { step in
            let angle = CGFloat(step) / 12 * 2 * .pi
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    static func offset(_ points: [CGPoint], by origin: CGPoint) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
    }
}

extension View {
    /// Reveals the view left to right as `progress` goes 0 → 1 (the pen's sweep).
    func writtenLeftToRight(progress: Double) -> some View {
        mask(alignment: .leading) {
            GeometryReader { geometry in
                Rectangle().frame(width: geometry.size.width * progress)
            }
        }
    }

    /// Reports a writing wiggle across this view as element `index`'s pen path.
    func reportsWritingPath(ofElement index: Int) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ElementPenPathsKey.self,
                    value: [
                        index: PenPaths.writing(
                            across: geometry.frame(in: .named(WhiteboardView.coordinateSpaceName)))
                    ])
            })
    }
}

// MARK: - Math steps

struct MathStepsFigureView: View {
    let spec: MathStepsSpec
    @ObservedObject var model: WhiteboardModel

    static let lineFontSize: CGFloat = 28
    static let smallestLineFontSize: CGFloat = 15
    /// The step number's circle and the gap after it.
    static let numberColumnWidth: CGFloat = 22 + 14

    var body: some View {
        GeometryReader { geometry in
            // Lines shrink to fit the board instead of running off its edge (owner's screenshot).
            let fullSizeRows = rows(fontSize: Self.lineFontSize)
            // Only short left sides line up on "=": one long "Maximize Z =" pushed every other
            // equation to the right (owner, simplex problem, D72).
            let alignedLeftSideCap = geometry.size.width * Self.largestAlignedLeftSideShare
            let fullSizeLeftSide = Self.leftSideWidth(of: fullSizeRows, cap: alignedLeftSideCap)
            let naturalWidth =
                Self.numberColumnWidth
                + (fullSizeRows.map { $0.width(leftSideWidth: fullSizeLeftSide) }.max() ?? 0)
            let fontSize = max(
                Self.smallestLineFontSize,
                min(
                    Self.lineFontSize,
                    Self.lineFontSize * (geometry.size.width - 8) / max(naturalWidth, 1)))
            let rows = rows(fontSize: fontSize)
            let leftSideWidth = Self.leftSideWidth(
                of: rows, cap: alignedLeftSideCap * fontSize / Self.lineFontSize)
            let latestWritten = (0..<rows.count).last { model.progress(ofElement: $0) > 0 }
            // Long solutions scroll: the board follows the step being written (a 10th step ran
            // off the bottom of a fixed board, owner's report, D65).
            ScrollViewReader { scroller in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: fontSize * 0.36) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            let isLatest = index == latestWritten
                            HStack(alignment: .center, spacing: 14) {
                                stepNumber(index + 1, isLatest: isLatest)
                                row.content(leftSideWidth: leftSideWidth)
                            }
                            .fixedSize()
                            .opacity(isLatest || latestWritten == nil ? 1 : 0.72)
                            .writtenLeftToRight(progress: model.progress(ofElement: index))
                            .reportsWritingPath(ofElement: index)
                            .id(index)
                        }
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.focusedElement) { _, element in
                    guard let element else { return }
                    withAnimation(.easeInOut(duration: WhiteboardPanel.scrollSeconds)) {
                        scroller.scrollTo(element, anchor: .bottom)
                    }
                }
            }
            .animation(.easeOut(duration: 0.3), value: latestWritten)
        }
    }

    private func rows(fontSize: CGFloat) -> [MathRow] {
        spec.steps.enumerated().map { index, step in
            MathRow(
                step: step, previous: index > 0 ? spec.steps[index - 1] : nil, fontSize: fontSize)
        }
    }

    /// A left side wider than this share of the board isn't aligned on "=".
    static let largestAlignedLeftSideShare: CGFloat = 0.3

    private static func leftSideWidth(of rows: [MathRow], cap: CGFloat) -> CGFloat {
        rows.compactMap(\.leftSideWidth).filter { $0 <= cap }.max() ?? 0
    }

    private func stepNumber(_ number: Int, isLatest: Bool) -> some View {
        Text("\(number)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundColor(
                isLatest ? .black.opacity(0.8) : WhiteboardView.chalkColor.opacity(0.5)
            )
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(isLatest ? WhiteboardView.highlightColor : Color.white.opacity(0.08))
            )
    }
}

/// One math line, split at its first "=" so lines align on it. LaTeX lines are typeset (D61);
/// plain lines, and LaTeX SwiftMath can't parse, are chalk text.
private struct MathRow {
    /// A typeset piece and its measured size.
    struct TypesetPiece {
        let latex: String
        let size: CGSize
    }

    static let highlightHex = "#FFB224"

    let step: String
    let fontSize: CGFloat
    let changedRanges: [Range<String.Index>]
    let leftSide: Range<String.Index>?
    let rightSide: Range<String.Index>?
    /// Set for typeset lines: the whole line, or its two sides when it splits at "=".
    let typesetWhole: TypesetPiece?
    let typesetLeft: TypesetPiece?
    let typesetRight: TypesetPiece?

    init(step rawStep: String, previous rawPrevious: String?, fontSize: CGFloat) {
        // D72: tableaux and `$…$` become LaTeX SwiftMath can typeset.
        let step = LatexMath.compatible(rawStep)
        let previous = rawPrevious.map(LatexMath.compatible)
        self.step = step
        self.fontSize = fontSize
        changedRanges = MathStepsDiff.changedRanges(from: previous, to: step)
        if let equals = step.firstIndex(of: "=") {
            leftSide = Self.trimmed(step.startIndex..<equals, in: step)
            rightSide = Self.trimmed(step.index(after: equals)..<step.endIndex, in: step)
        } else {
            leftSide = nil
            rightSide = nil
        }
        var whole: TypesetPiece?
        var left: TypesetPiece?
        var right: TypesetPiece?
        if LatexMath.looksLikeLatex(step) {
            let highlighted = LatexMath.highlightingChanges(
                from: previous, to: step, colorHex: Self.highlightHex)
            if let size = LatexLineView.size(of: highlighted, fontSize: fontSize) {
                whole = TypesetPiece(latex: highlighted, size: size)
                if let split = LatexMath.splitAtTopLevelEquals(highlighted),
                    let leftSize = LatexLineView.size(of: split.left, fontSize: fontSize),
                    let rightSize = LatexLineView.size(of: split.right, fontSize: fontSize)
                {
                    left = TypesetPiece(latex: split.left, size: leftSize)
                    right = TypesetPiece(latex: split.right, size: rightSize)
                }
            }
        }
        typesetWhole = whole
        typesetLeft = left
        typesetRight = right
    }

    var leftSideWidth: CGFloat? {
        if typesetWhole != nil { return typesetLeft?.size.width }
        return leftSide.map { measuredWidth(String(step[$0])) }
    }

    /// Lines up on "=" only when its left side fits the shared column.
    func isAligned(leftSideWidth column: CGFloat) -> Bool {
        guard let leftSideWidth else { return false }
        return leftSideWidth <= column + 0.5
    }

    /// The row's width with the given left column (text measured bold: an upper bound).
    func width(leftSideWidth: CGFloat) -> CGFloat {
        guard isAligned(leftSideWidth: leftSideWidth) else {
            return typesetWhole?.size.width ?? measuredWidth(step)
        }
        if let typesetWhole {
            guard let typesetRight else { return typesetWhole.size.width }
            return leftSideWidth + 10 + measuredWidth("=") + 10 + typesetRight.size.width
        }
        guard let rightSide else { return measuredWidth(step) }
        return leftSideWidth + 10 + measuredWidth("=") + 10 + measuredWidth(String(step[rightSide]))
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        let font =
            NSFont(name: "ChalkboardSE-Bold", size: fontSize) ?? .systemFont(ofSize: fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder func content(leftSideWidth: CGFloat) -> some View {
        if let typesetWhole {
            if isAligned(leftSideWidth: leftSideWidth), let typesetLeft, let typesetRight {
                HStack(alignment: .center, spacing: 10) {
                    typeset(typesetLeft).frame(width: leftSideWidth, alignment: .trailing)
                    equalsSign
                    typeset(typesetRight)
                }
            } else {
                typeset(typesetWhole)
            }
        } else if isAligned(leftSideWidth: leftSideWidth), let leftSide, let rightSide {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(attributed(leftSide)).frame(width: leftSideWidth, alignment: .trailing)
                equalsSign
                Text(attributed(rightSide))
            }
        } else {
            Text(attributed(step.startIndex..<step.endIndex))
        }
    }

    private var equalsSign: some View {
        Text("=").font(WhiteboardView.chalkFont(size: fontSize))
            .foregroundColor(WhiteboardView.chalkColor.opacity(0.8))
    }

    private func typeset(_ piece: TypesetPiece) -> some View {
        LatexLineView(latex: piece.latex, fontSize: fontSize)
            .frame(width: piece.size.width, height: piece.size.height)
    }

    /// The text in `range`, with the changed spans in the `explain` colour and bold.
    private func attributed(_ range: Range<String.Index>) -> AttributedString {
        var result = AttributedString()
        func append(_ part: Range<String.Index>, changed: Bool) {
            guard !part.isEmpty else { return }
            var piece = AttributedString(String(step[part]))
            piece.font = WhiteboardView.chalkFont(size: fontSize, bold: changed)
            piece.foregroundColor =
                changed ? WhiteboardView.highlightColor : WhiteboardView.chalkColor
            result += piece
        }
        var cursor = range.lowerBound
        for changed in changedRanges {
            let start = max(changed.lowerBound, range.lowerBound)
            let end = min(changed.upperBound, range.upperBound)
            guard start < end, start >= cursor else { continue }
            append(cursor..<start, changed: false)
            append(start..<end, changed: true)
            cursor = end
        }
        append(cursor..<range.upperBound, changed: false)
        return result
    }

    private static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<
        String.Index
    > {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while upper > lower, text[text.index(before: upper)].isWhitespace {
            upper = text.index(before: upper)
        }
        return lower..<upper
    }
}

// MARK: - Number line

struct NumberLineFigureView: View {
    let spec: NumberLineSpec
    @ObservedObject var model: WhiteboardModel

    static let markLabelSize: CGFloat = 17
    static let levelHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let origin = geometry.frame(in: .named(WhiteboardView.coordinateSpaceName)).origin
            let layout = NumberLineLayout.layout(spec, width: width, padding: 28, characterWidth: 8)
            let axisY = geometry.size.height * 0.68
            let axisProgress = model.progress(ofElement: 0)
            let highestLabelLevel =
                layout.marks.filter { $0.label != nil }.map(\.labelLevel).max() ?? -1
            let brackets = layout.intervals.enumerated().map { index, interval in
                (
                    fromX: min(interval.fromX, interval.toX - 10),
                    toX: max(interval.toX, interval.fromX + 10),
                    y: axisY - 40 - CGFloat(highestLabelLevel + 1) * Self.levelHeight - CGFloat(
                        index) * 32,
                    label: interval.label
                )
            }
            ZStack(alignment: .topLeading) {
                AxisShape(
                    startX: layout.axisStartX - 10, endX: layout.axisEndX + 10, y: axisY,
                    tickXs: layout.ticks.map(\.x)
                )
                .trim(from: 0, to: axisProgress)
                .stroke(
                    WhiteboardView.chalkColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ForEach(Array(layout.ticks.enumerated()), id: \.offset) { _, tick in
                    if let label = tick.label {
                        Text(label)
                            .font(WhiteboardView.chalkFont(size: 14))
                            .foregroundColor(WhiteboardView.chalkColor.opacity(0.75))
                            .fixedSize()
                            .position(
                                x: Self.clampedX(tick.x, label: label, size: 14, width: width),
                                y: axisY + 24
                            )
                            .opacity(axisProgress)
                    }
                }
                ForEach(Array(layout.marks.enumerated()), id: \.offset) { index, mark in
                    markView(
                        mark, axisY: axisY, width: width,
                        progress: model.progress(ofElement: 1 + index))
                }
                ForEach(Array(brackets.enumerated()), id: \.offset) { index, bracket in
                    let element = 1 + layout.marks.count + index
                    BracketShape(fromX: bracket.fromX, toX: bracket.toX, y: bracket.y, legLength: 8)
                        .trim(from: 0, to: model.progress(ofElement: element))
                        .stroke(
                            WhiteboardView.highlightColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let label = bracket.label {
                        Text(label)
                            .font(WhiteboardView.chalkFont(size: 15, bold: true))
                            .foregroundColor(WhiteboardView.highlightColor)
                            .fixedSize()
                            .position(
                                x: Self.clampedX(
                                    (bracket.fromX + bracket.toX) / 2, label: label, size: 15,
                                    width: width),
                                y: bracket.y - 16
                            )
                            .opacity(model.progress(ofElement: element))
                    }
                }
            }
            .preference(
                key: ElementPenPathsKey.self,
                value: Self.penPaths(
                    layout: layout, axisY: axisY, brackets: brackets, origin: origin))
        }
    }

    private static func penPaths(
        layout: NumberLineLayout, axisY: CGFloat,
        brackets: [(fromX: CGFloat, toX: CGFloat, y: CGFloat, label: String?)], origin: CGPoint
    ) -> [Int: [CGPoint]] {
        var paths: [Int: [CGPoint]] = [
            0: [
                CGPoint(x: layout.axisStartX - 10, y: axisY),
                CGPoint(x: layout.axisEndX + 10, y: axisY),
            ]
        ]
        for (index, mark) in layout.marks.enumerated() {
            paths[1 + index] = PenPaths.loop(around: CGPoint(x: mark.x, y: axisY), radius: 9)
        }
        for (index, bracket) in brackets.enumerated() {
            paths[1 + layout.marks.count + index] = [
                CGPoint(x: bracket.fromX, y: bracket.y + 8),
                CGPoint(x: bracket.fromX, y: bracket.y),
                CGPoint(x: bracket.toX, y: bracket.y), CGPoint(x: bracket.toX, y: bracket.y + 8),
            ]
        }
        return paths.mapValues { PenPaths.offset($0, by: origin) }
    }

    private func markView(
        _ mark: NumberLineLayout.PlacedMark, axisY: CGFloat, width: CGFloat, progress: Double
    ) -> some View {
        ZStack {
            Circle()
                .fill(WhiteboardView.markColor)
                .frame(width: 12, height: 12)
                .shadow(color: WhiteboardView.markColor.opacity(0.8), radius: 6)
                .scaleEffect(progress)
                .position(x: mark.x, y: axisY)
            if let label = mark.label {
                let text = label + (mark.isOutOfRange ? " →" : "")
                Text(text)
                    .font(WhiteboardView.chalkFont(size: Self.markLabelSize, bold: true))
                    .foregroundColor(WhiteboardView.chalkColor)
                    .fixedSize()
                    .position(
                        x: Self.clampedX(
                            mark.x, label: text, size: Self.markLabelSize, width: width),
                        y: axisY - 30 - CGFloat(mark.labelLevel) * Self.levelHeight
                    )
                    .opacity(progress)
            }
        }
    }

    /// Keeps a centred label inside the board.
    static func clampedX(_ x: CGFloat, label: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let halfWidth = CGFloat(label.count) * size * 0.3 + 6
        return min(max(x, halfWidth), max(halfWidth, width - halfWidth))
    }
}

// MARK: - Geometry (D59)

struct GeometryFigureView: View {
    let spec: GeometrySpec
    @ObservedObject var model: WhiteboardModel

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .named(WhiteboardView.coordinateSpaceName)).origin
            let layout = GeometryLayout.layout(spec, in: geometry.size, padding: 56)
            let segmentCount = spec.segments.count
            ZStack(alignment: .topLeading) {
                ForEach(Array(spec.segments.enumerated()), id: \.offset) { index, segment in
                    if let from = layout.positions[segment.from],
                        let to = layout.positions[segment.to]
                    {
                        SegmentShape(from: from, to: to)
                            .trim(from: 0, to: model.progress(ofElement: index))
                            .stroke(
                                WhiteboardView.chalkColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        if let label = segment.label,
                            let position = layout.segmentLabelPositions[index]
                        {
                            Text(label)
                                .font(WhiteboardView.chalkFont(size: 17, bold: true))
                                .foregroundColor(WhiteboardView.highlightColor)
                                .fixedSize()
                                .position(position)
                                .opacity(model.progress(ofElement: index))
                        }
                    }
                }
                ForEach(spec.points, id: \.name) { point in
                    let firstSide = spec.segments.firstIndex {
                        $0.from == point.name || $0.to == point.name
                    }
                    let progress = firstSide.map { model.progress(ofElement: $0) } ?? 1
                    if let position = layout.positions[point.name],
                        let labelPosition = layout.pointLabelPositions[point.name]
                    {
                        Circle()
                            .fill(WhiteboardView.chalkColor)
                            .frame(width: 6, height: 6)
                            .position(position)
                            .opacity(progress)
                        Text(point.name)
                            .font(WhiteboardView.chalkFont(size: 18, bold: true))
                            .foregroundColor(WhiteboardView.chalkColor)
                            .fixedSize()
                            .position(labelPosition)
                            .opacity(progress)
                    }
                }
                ForEach(Array(layout.angleMarks.enumerated()), id: \.offset) { index, mark in
                    let element = segmentCount + index
                    AngleMarkShape(mark: mark)
                        .trim(from: 0, to: model.progress(ofElement: element))
                        .stroke(
                            WhiteboardView.highlightColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let label = mark.label {
                        Text(label)
                            .font(WhiteboardView.chalkFont(size: 15, bold: true))
                            .foregroundColor(WhiteboardView.highlightColor)
                            .fixedSize()
                            .position(mark.labelPosition)
                            .opacity(model.progress(ofElement: element))
                    }
                }
            }
            .preference(
                key: ElementPenPathsKey.self,
                value: Self.penPaths(spec: spec, layout: layout, origin: origin))
        }
    }

    private static func penPaths(spec: GeometrySpec, layout: GeometryLayout, origin: CGPoint)
        -> [Int: [CGPoint]]
    {
        var paths: [Int: [CGPoint]] = [:]
        for (index, segment) in spec.segments.enumerated() {
            if let from = layout.positions[segment.from], let to = layout.positions[segment.to] {
                paths[index] = [from, to]
            }
        }
        for (index, mark) in layout.angleMarks.enumerated() {
            paths[spec.segments.count + index] = AngleMarkShape.points(for: mark)
        }
        return paths.mapValues { PenPaths.offset($0, by: origin) }
    }
}

struct SegmentShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

/// An arc between two sides, or the small square of a right angle.
struct AngleMarkShape: Shape {
    let mark: GeometryLayout.AngleMark

    static func points(for mark: GeometryLayout.AngleMark) -> [CGPoint] {
        if mark.isRight {
            let side = mark.radius * 0.6
            let first = CGPoint(
                x: mark.vertex.x + cos(mark.startAngle) * side,
                y: mark.vertex.y + sin(mark.startAngle) * side)
            let second = CGPoint(
                x: mark.vertex.x + cos(mark.endAngle) * side,
                y: mark.vertex.y + sin(mark.endAngle) * side)
            let corner = CGPoint(
                x: first.x + second.x - mark.vertex.x, y: first.y + second.y - mark.vertex.y)
            return [first, corner, second]
        }
        return (0...12).map { step in
            let angle = mark.startAngle + (mark.endAngle - mark.startAngle) * CGFloat(step) / 12
            return CGPoint(
                x: mark.vertex.x + cos(angle) * mark.radius,
                y: mark.vertex.y + sin(angle) * mark.radius)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Self.points(for: mark)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// The axis line with its ticks, in drawing order (so `trim` draws it left to right).
struct AxisShape: Shape {
    let startX: CGFloat
    let endX: CGFloat
    let y: CGFloat
    let tickXs: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: startX, y: y))
        for tickX in tickXs.sorted() {
            path.addLine(to: CGPoint(x: tickX, y: y))
            path.addLine(to: CGPoint(x: tickX, y: y - 7))
            path.addLine(to: CGPoint(x: tickX, y: y + 7))
            path.addLine(to: CGPoint(x: tickX, y: y))
        }
        path.addLine(to: CGPoint(x: endX, y: y))
        // Arrowhead: the line goes on.
        path.addLine(to: CGPoint(x: endX - 9, y: y - 6))
        path.move(to: CGPoint(x: endX, y: y))
        path.addLine(to: CGPoint(x: endX - 9, y: y + 6))
        return path
    }
}

/// ⎴-shaped bracket over an interval.
struct BracketShape: Shape {
    let fromX: CGFloat
    let toX: CGFloat
    let y: CGFloat
    let legLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: fromX, y: y + legLength))
        path.addLine(to: CGPoint(x: fromX, y: y))
        path.addLine(to: CGPoint(x: toX, y: y))
        path.addLine(to: CGPoint(x: toX, y: y + legLength))
        return path
    }
}
