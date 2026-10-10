import CoreGraphics

/// What the learner drew while holding ⌃⌥ (§4.2.5), in display points (top-left origin).
public struct LearnerStroke: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A closed loop: "this region".
        case lasso
        /// An open stroke (an underline, a scribble): "this area".
        case area
    }

    public var kind: Kind
    /// The region the strokes point at, in display points; what gets cropped for the model.
    public var region: CGRect
}

/// Classifies the strokes of one ⌃⌥ press (§4.2.5; the demo cut keeps the lasso, §4.7, and
/// treats any other stroke as "this area"). Pure, so the gesture rules are unit-tested.
public enum LassoClassifier {
    /// Shorter or smaller strokes are clicks or jitter, not drawing.
    public static let minimumPathLengthInPoints: CGFloat = 40
    public static let minimumStrokeSideInPoints: CGFloat = 12
    /// A loop must be at least this thick in both directions (a back-and-forth line isn't one).
    public static let minimumLoopSideInPoints: CGFloat = 16
    /// Regions are at least this big, so an underline's crop includes the text above it.
    public static let minimumRegionSideInPoints: CGFloat = 24

    public static func classify(_ strokes: [[CGPoint]]) -> LearnerStroke? {
        var isLasso = false
        var region: CGRect?
        for points in strokes {
            guard let bounds = boundingBox(of: points),
                max(bounds.width, bounds.height) >= minimumStrokeSideInPoints,
                pathLength(of: points) >= minimumPathLengthInPoints,
                let first = points.first, let last = points.last
            else { continue }
            let closingGap = hypot(last.x - first.x, last.y - first.y)
            let diagonal = hypot(bounds.width, bounds.height)
            if closingGap <= max(30, diagonal * 0.3),
                min(bounds.width, bounds.height) >= minimumLoopSideInPoints
            {
                isLasso = true
            }
            region = region?.union(bounds) ?? bounds
        }
        guard let region else { return nil }
        return LearnerStroke(kind: isLasso ? .lasso : .area, region: paddedToMinimum(region))
    }

    /// Thin regions grow: upward for a flat stroke (an underline sits below its text), and
    /// sideways for a tall one.
    static func paddedToMinimum(_ region: CGRect) -> CGRect {
        var padded = region
        if padded.height < minimumRegionSideInPoints {
            padded.origin.y = region.maxY - minimumRegionSideInPoints
            padded.size.height = minimumRegionSideInPoints + 4
        }
        if padded.width < minimumRegionSideInPoints {
            padded.origin.x = region.midX - minimumRegionSideInPoints / 2
            padded.size.width = minimumRegionSideInPoints
        }
        return padded
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    static func pathLength(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}
