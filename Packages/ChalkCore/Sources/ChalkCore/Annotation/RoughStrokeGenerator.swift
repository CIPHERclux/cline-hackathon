import CoreGraphics
import Foundation

/// The paths for one hand-drawn mark (§4.2.1 style, §5.5): `strokes` animate in order
/// (`strokeEnd` 0→1), `accents` (arrowheads) pop in after them, `fill` is the translucent
/// highlighter band. Coordinates are overlay-local points, top-left origin.
public struct RoughDrawing {
    public var strokes: [CGPath]
    public var accents: [CGPath]
    public var fill: CGPath?

    /// Total stroke length in points, to scale the draw animation (§5.5: 250–600 ms).
    public var approximateLength: CGFloat

    public init(strokes: [CGPath], accents: [CGPath], fill: CGPath?, approximateLength: CGFloat) {
        self.strokes = strokes
        self.accents = accents
        self.fill = fill
        self.approximateLength = approximateLength
    }
}

/// Excalidraw-like strokes in the spirit of Rough.js (MIT), reimplemented natively (§4.2.1):
/// slight wobble, bowed lines, overshooting double-pass ellipses. Seeded per mark, so a redraw
/// of the same mark never jitters (§5.5: roughness 1.0, bowing 0.6).
public enum RoughStrokeGenerator {
    public static let roughness: CGFloat = 1.0
    public static let bowing: CGFloat = 0.6
    /// Second pass of an ellipse sits this far from the first (§5.5: 0.6 pt).
    public static let doubleStrokeOffset: CGFloat = 0.6
    /// Breathing room between a shape and what it surrounds.
    public static let padding: CGFloat = 6

    public static func ellipse(around rect: CGRect, seed: UInt64) -> RoughDrawing {
        var random = SeededRandom(seed: seed)
        let padded = rect.insetBy(
            dx: -padding - rect.width * 0.08, dy: -padding - rect.height * 0.12)
        let first = roughEllipsePath(in: padded, random: &random, radialOffset: 0)
        let second = roughEllipsePath(in: padded, random: &random, radialOffset: doubleStrokeOffset)
        let length = ellipseCircumference(padded)
        return RoughDrawing(
            strokes: [first, second], accents: [], fill: nil, approximateLength: length * 2.2)
    }

    /// The "here" ring around a point (§4.2.1 `ring`).
    public static func ring(around center: CGPoint, radius: CGFloat = 22, seed: UInt64)
        -> RoughDrawing
    {
        ellipse(
            around: CGRect(
                x: center.x - radius + padding, y: center.y - radius + padding,
                width: 2 * (radius - padding), height: 2 * (radius - padding)),
            seed: seed)
    }

    public static func rectangle(around rect: CGRect, seed: UInt64) -> RoughDrawing {
        var random = SeededRandom(seed: seed)
        let padded = rect.insetBy(dx: -padding, dy: -padding)
        let corners = [
            CGPoint(x: padded.minX, y: padded.minY), CGPoint(x: padded.maxX, y: padded.minY),
            CGPoint(x: padded.maxX, y: padded.maxY), CGPoint(x: padded.minX, y: padded.maxY),
        ]
        let path = CGMutablePath()
        for index in 0..<4 {
            appendRoughLine(
                to: path, from: corners[index], to: corners[(index + 1) % 4], random: &random,
                moveFirst: index == 0)
        }
        return RoughDrawing(
            strokes: [path], accents: [], fill: nil,
            approximateLength: 2 * (padded.width + padded.height))
    }

    public static func underline(below rect: CGRect, seed: UInt64) -> RoughDrawing {
        var random = SeededRandom(seed: seed)
        let path = CGMutablePath()
        let y = rect.maxY + 3
        appendRoughLine(
            to: path, from: CGPoint(x: rect.minX - 2, y: y), to: CGPoint(x: rect.maxX + 2, y: y),
            random: &random, moveFirst: true)
        return RoughDrawing(
            strokes: [path], accents: [], fill: nil, approximateLength: rect.width + 4)
    }

    /// Translucent marker swipe over a text line (§4.2.1 `highlight`), slightly skewed by hand.
    public static func highlight(over rect: CGRect, seed: UInt64) -> RoughDrawing {
        var random = SeededRandom(seed: seed)
        let band = rect.insetBy(dx: -3, dy: -2)
        let skew = (random.nextUnit() - 0.5) * 3 * roughness
        let path = CGMutablePath()
        path.move(to: CGPoint(x: band.minX, y: band.minY + skew))
        path.addLine(to: CGPoint(x: band.maxX, y: band.minY - skew))
        path.addLine(to: CGPoint(x: band.maxX, y: band.maxY - skew))
        path.addLine(to: CGPoint(x: band.minX, y: band.maxY + skew))
        path.closeSubpath()
        return RoughDrawing(strokes: [], accents: [], fill: path, approximateLength: band.width)
    }

    public static func arrow(from start: CGPoint, to end: CGPoint, seed: UInt64) -> RoughDrawing {
        var random = SeededRandom(seed: seed)
        let shaft = CGMutablePath()
        appendRoughLine(to: shaft, from: start, to: end, random: &random, moveFirst: true)
        let angle = atan2(end.y - start.y, end.x - start.x)
        return RoughDrawing(
            strokes: [shaft], accents: [arrowhead(at: end, angle: angle)], fill: nil,
            approximateLength: hypot(end.x - start.x, end.y - start.y))
    }

    /// Bowed arrow for relationships between distant items (§4.2.1 `curved_arrow`).
    public static func curvedArrow(from start: CGPoint, to end: CGPoint, seed: UInt64)
        -> RoughDrawing
    {
        var random = SeededRandom(seed: seed)
        let length = hypot(end.x - start.x, end.y - start.y)
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Bow to one side by a quarter of the length, a little randomly.
        let normal = CGPoint(
            x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
        let bow = length * (0.22 + random.nextUnit() * 0.08)
        let control = CGPoint(x: midpoint.x + normal.x * bow, y: midpoint.y + normal.y * bow)
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addQuadCurve(to: end, control: control)
        let angle = atan2(end.y - control.y, end.x - control.x)
        return RoughDrawing(
            strokes: [shaft], accents: [arrowhead(at: end, angle: angle)], fill: nil,
            approximateLength: length * 1.15)
    }

    // MARK: - Pieces

    private static func arrowhead(at tip: CGPoint, angle: CGFloat, length: CGFloat = 12) -> CGPath {
        let path = CGMutablePath()
        for side in [-1.0, 1.0] {
            let wingAngle = angle + .pi - side * (.pi / 7)
            path.move(to: tip)
            path.addLine(
                to: CGPoint(x: tip.x + cos(wingAngle) * length, y: tip.y + sin(wingAngle) * length))
        }
        return path
    }

    /// A line with jittered ends and a slight bow through the middle, like a hand-drawn stroke.
    private static func appendRoughLine(
        to path: CGMutablePath, from start: CGPoint, to end: CGPoint, random: inout SeededRandom,
        moveFirst: Bool
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let jitter = min(2, length * 0.02) * roughness
        let jitteredStart = CGPoint(
            x: start.x + random.symmetric() * jitter, y: start.y + random.symmetric() * jitter)
        let jitteredEnd = CGPoint(
            x: end.x + random.symmetric() * jitter, y: end.y + random.symmetric() * jitter)
        let normal = CGPoint(
            x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
        let bow = random.symmetric() * length * 0.015 * bowing * 2
        let control = CGPoint(
            x: (jitteredStart.x + jitteredEnd.x) / 2 + normal.x * bow,
            y: (jitteredStart.y + jitteredEnd.y) / 2 + normal.y * bow)
        if moveFirst { path.move(to: jitteredStart) } else { path.addLine(to: jitteredStart) }
        path.addQuadCurve(to: jitteredEnd, control: control)
    }

    /// One pass around an ellipse: radius wobble, a random start angle and an overshoot past the
    /// start, so it reads as drawn in one go rather than as a perfect geometric shape.
    private static func roughEllipsePath(
        in rect: CGRect, random: inout SeededRandom, radialOffset: CGFloat
    ) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2 + radialOffset
        let radiusY = rect.height / 2 + radialOffset
        let startAngle = random.nextUnit() * 2 * .pi
        let overshoot = (0.08 + random.nextUnit() * 0.12) * 2 * .pi
        let pointCount = 32
        let path = CGMutablePath()
        for index in 0...pointCount {
            let progress = CGFloat(index) / CGFloat(pointCount)
            let angle = startAngle + progress * (2 * .pi + overshoot)
            let wobble = 1 + random.symmetric() * 0.025 * roughness
            let point = CGPoint(
                x: center.x + cos(angle) * radiusX * wobble,
                y: center.y + sin(angle) * radiusY * wobble)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private static func ellipseCircumference(_ rect: CGRect) -> CGFloat {
        let semiMajor = rect.width / 2
        let semiMinor = rect.height / 2
        // Ramanujan's approximation.
        return .pi
            * (3 * (semiMajor + semiMinor)
                - sqrt((3 * semiMajor + semiMinor) * (semiMajor + 3 * semiMinor)))
    }
}

/// SplitMix64: tiny, fast and deterministic, so a mark's look depends only on its seed.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }

    /// Uniform in [-1, 1).
    public mutating func symmetric() -> CGFloat {
        nextUnit() * 2 - 1
    }

    /// A stable seed from a mark id, so the same mark redraws identically across launches.
    public static func seed(for identifier: String) -> UInt64 {
        identifier.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}
