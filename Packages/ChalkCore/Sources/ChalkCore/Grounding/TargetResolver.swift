import CoreGraphics
import Foundation

/// Where a script target landed, in native pixels of the capture (§6.2 target resolution).
public struct ResolvedTarget: Equatable, Sendable {
    public var rectInNativePixels: CGRect
    /// A guessed point with nothing to snap to, or a raw pixel target (§6.2 rule 5).
    public var isLowConfidence: Bool
    public var source: Source
    /// The on-screen text this target landed on, if any: what verification re-reads (§6.2 f).
    public var matchedText: String? = nil
    /// Landed on an accessibility element: an exact frame with nothing to re-read (D74).
    public var isFromAccessibility = false

    public enum Source: String, Sendable {
        case mark, text, snappedPoint, rawPoint, region, relative
    }
}

/// Resolves Teaching Script targets against the current screen (§6.2 order: mark → text →
/// region → relative → px). The basic version for S06; S08 adds the verify pass and the zoom
/// fallback.
public struct TargetResolver: Sendable {
    public let screenSpace: ScreenSpace
    /// Capped marks: the only valid ids for `{"mark": n}` (they're what the model was shown).
    public let marks: [Mark]
    /// Uncapped candidates: what text and points resolve against (D48).
    public let snapTargets: [Mark]
    public let cursorInNativePixels: CGPoint?

    /// A point with nothing under it becomes a box this many points wide.
    static let unsnappedBoxSidePoints: CGFloat = 32

    public init(
        screenSpace: ScreenSpace, marks: [Mark], snapTargets: [Mark], cursorInNativePixels: CGPoint?
    ) {
        self.screenSpace = screenSpace
        self.marks = marks
        self.snapTargets = snapTargets
        self.cursorInNativePixels = cursorInNativePixels
    }

    public func resolve(_ target: TargetDescriptor) -> ResolvedTarget? {
        switch target {
        case .mark(let identifier):
            guard let mark = marks.first(where: { $0.id == identifier }) else { return nil }
            return ResolvedTarget(
                rectInNativePixels: mark.box, isLowConfidence: false, source: .mark,
                matchedText: mark.kind == .text ? mark.text : nil)

        case .text(let text, let near, let within):
            // `near` names a nearby target; `within` names the panel or heading it sits under
            // ("Export" within "Assets"). Either one breaks ties; otherwise the cursor does.
            let nearPoint = near.flatMap(resolve).map {
                CGPoint(x: $0.rectInNativePixels.midX, y: $0.rectInNativePixels.midY)
            }
            let withinPoint = within.flatMap { bestTextMatch(for: $0, near: cursorInNativePixels) }?
                .center
            guard
                let match = bestTextMatch(
                    for: text, near: nearPoint ?? withinPoint ?? cursorInNativePixels)
            else {
                // The label isn't readable on screen (a placeholder, a stylised button): the
                // model's point beside it still places the mark (D73), as a guess the zoom
                // pass can refine. Before, the drawing was dropped and nothing was circled.
                return near.flatMap(resolve)
            }
            return ResolvedTarget(
                rectInNativePixels: match.box, isLowConfidence: false, source: .text,
                matchedText: match.text, isFromAccessibility: match.isFromAccessibility)

        case .pixel(let x, let y, let space):
            let modelPoint =
                space == "norm1000"
                ? screenSpace.norm1000ToModelPixel(CGPoint(x: x, y: y))
                : CGPoint(
                    x: min(max(x, 0), screenSpace.modelPixelSize.width),
                    y: min(max(y, 0), screenSpace.modelPixelSize.height))
            let nativePoint = screenSpace.modelPixelToNativePixel(modelPoint)
            // Snap (D40/D48): the smallest candidate under the point gives an exact outline.
            if let snapped = MarkSelection.smallestMark(containing: nativePoint, in: snapTargets) {
                return ResolvedTarget(
                    rectInNativePixels: snapped.box, isLowConfidence: false, source: .snappedPoint,
                    matchedText: snapped.kind == .text ? snapped.text : nil,
                    isFromAccessibility: snapped.isFromAccessibility)
            }
            let side = Self.unsnappedBoxSidePoints * screenSpace.backingScale
            return ResolvedTarget(
                rectInNativePixels: CGRect(
                    x: nativePoint.x - side / 2, y: nativePoint.y - side / 2, width: side,
                    height: side),
                isLowConfidence: true, source: .rawPoint)

        case .region(let rect, _):
            let modelRect = CGRect(
                x: rect.x * screenSpace.modelPixelSize.width,
                y: rect.y * screenSpace.modelPixelSize.height,
                width: rect.width * screenSpace.modelPixelSize.width,
                height: rect.height * screenSpace.modelPixelSize.height)
            let origin = screenSpace.modelPixelToNativePixel(modelRect.origin)
            let farCorner = screenSpace.modelPixelToNativePixel(
                CGPoint(x: modelRect.maxX, y: modelRect.maxY))
            return ResolvedTarget(
                rectInNativePixels: CGRect(
                    x: origin.x, y: origin.y, width: farCorner.x - origin.x,
                    height: farCorner.y - origin.y),
                isLowConfidence: false, source: .region)

        case .relative(let anchorTarget, let position, let gap):
            guard let anchor = resolve(anchorTarget) else { return nil }
            let anchorRect = anchor.rectInNativePixels
            let gapPixels = (gap ?? 12) * screenSpace.backingScale
            let point: CGPoint
            switch position {
            case .above: point = CGPoint(x: anchorRect.midX, y: anchorRect.minY - gapPixels)
            case .below: point = CGPoint(x: anchorRect.midX, y: anchorRect.maxY + gapPixels)
            case .left: point = CGPoint(x: anchorRect.minX - gapPixels, y: anchorRect.midY)
            case .right: point = CGPoint(x: anchorRect.maxX + gapPixels, y: anchorRect.midY)
            }
            return ResolvedTarget(
                rectInNativePixels: CGRect(origin: point, size: .zero),
                isLowConfidence: anchor.isLowConfidence, source: .relative)
        }
    }

    /// Fuzzy OCR match (§6.2 "text anchor: fuzzy OCR match, nearest the cursor"): the best
    /// `FuzzyTextMatch` rank wins; ties go to the one nearest `near`.
    func bestTextMatch(for text: String, near: CGPoint?) -> Mark? {
        rankedTextMatches(for: text, near: near).first
    }

    /// Every OCR line matching `text`, best rank first, then nearest `near` (the alternatives
    /// for §6.2 f "try the next best mark").
    public func rankedTextMatches(for text: String, near: CGPoint?) -> [Mark] {
        let ranked = snapTargets.compactMap { mark -> (mark: Mark, rank: Int)? in
            guard mark.kind == .text, let markText = mark.text,
                let rank = FuzzyTextMatch.rank(candidate: markText, wanted: text)
            else { return nil }
            return (mark, rank)
        }
        func distance(_ mark: Mark) -> CGFloat {
            guard let near else { return 0 }
            return hypot(mark.center.x - near.x, mark.center.y - near.y)
        }
        return ranked.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : distance($0.mark) < distance($1.mark)
        }.map(\.mark)
    }
}
