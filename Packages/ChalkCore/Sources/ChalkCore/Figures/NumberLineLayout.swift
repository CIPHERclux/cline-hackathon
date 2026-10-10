import CoreGraphics
import Foundation

/// Lays out a number line (§4.2.3 "Linear"): tick and mark positions, short labels, and tick
/// labels thinned so none overlap. Pure; the whiteboard only draws what this returns.
public struct NumberLineLayout: Equatable, Sendable {
    public struct Tick: Equatable, Sendable {
        public var value: Double
        public var x: CGFloat
        /// Nil when thinned out to avoid overlapping its neighbour.
        public var label: String?
    }

    public struct PlacedMark: Equatable, Sendable {
        public var x: CGFloat
        public var label: String?
        /// Outside min…max: drawn at the end it overshoots.
        public var isOutOfRange: Bool
        /// 0 is just above the axis; higher levels stack up so close marks' labels don't overlap.
        public var labelLevel: Int = 0
    }

    public struct PlacedInterval: Equatable, Sendable {
        public var fromX: CGFloat
        public var toX: CGFloat
        public var label: String?
    }

    public var axisStartX: CGFloat
    public var axisEndX: CGFloat
    public var ticks: [Tick]
    public var marks: [PlacedMark]
    public var intervals: [PlacedInterval]

    public static func layout(
        _ spec: NumberLineSpec, width: CGFloat, padding: CGFloat = 24, characterWidth: CGFloat = 7
    ) -> NumberLineLayout {
        let axisStartX = padding
        let axisEndX = max(padding + 1, width - padding)
        func x(for value: Double) -> CGFloat {
            let clamped = min(max(value, spec.minimum), spec.maximum)
            let fraction = (clamped - spec.minimum) / (spec.maximum - spec.minimum)
            return axisStartX + CGFloat(fraction) * (axisEndX - axisStartX)
        }
        let tickValues =
            spec.ticks
            ?? generatedTicks(
                minimum: spec.minimum, maximum: spec.maximum,
                step: spec.step ?? niceTickStep(range: spec.maximum - spec.minimum))
        // Thin labels left to right: keep one only if it clears the last kept label.
        var ticks: [Tick] = []
        var lastLabelRightEdge = -CGFloat.infinity
        for value in tickValues.sorted() {
            let tickX = x(for: value)
            let label = format(value)
            let halfWidth = CGFloat(label.count) * characterWidth / 2
            let fits = tickX - halfWidth >= lastLabelRightEdge
            if fits { lastLabelRightEdge = tickX + halfWidth + characterWidth / 2 }
            ticks.append(Tick(value: value, x: tickX, label: fits ? label : nil))
        }
        // Mark labels, left to right: each takes the lowest level where it clears the labels
        // already there.
        var marks = spec.marks.map {
            PlacedMark(
                x: x(for: $0.value), label: $0.label,
                isOutOfRange: $0.value < spec.minimum || $0.value > spec.maximum)
        }
        var labelRightEdgeByLevel: [CGFloat] = []
        for index in marks.indices.sorted(by: { marks[$0].x < marks[$1].x }) {
            guard let label = marks[index].label else { continue }
            let halfWidth = CGFloat(label.count + 2) * characterWidth / 2
            let level =
                labelRightEdgeByLevel.firstIndex { marks[index].x - halfWidth >= $0 }
                ?? labelRightEdgeByLevel.count
            if level == labelRightEdgeByLevel.count {
                labelRightEdgeByLevel.append(marks[index].x + halfWidth)
            } else {
                labelRightEdgeByLevel[level] = marks[index].x + halfWidth
            }
            marks[index].labelLevel = level
        }
        return NumberLineLayout(
            axisStartX: axisStartX, axisEndX: axisEndX, ticks: ticks,
            marks: marks,
            intervals: spec.intervals.map {
                PlacedInterval(fromX: x(for: $0.from), toX: x(for: $0.to), label: $0.label)
            })
    }

    /// A 1-2-5 × 10ⁿ step giving about 5–10 ticks.
    public static func niceTickStep(range: Double) -> Double {
        guard range > 0, range.isFinite else { return 1 }
        let rough = range / 10
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let nice: Double = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 5 ? 5 : 10
        return (nice * magnitude * 1e12).rounded() / 1e12
    }

    static func generatedTicks(minimum: Double, maximum: Double, step: Double) -> [Double] {
        guard step > 0 else { return [minimum, maximum] }
        var values: [Double] = []
        var value = (minimum / step).rounded(.up) * step
        while value <= maximum + step * 1e-9, values.count < 50 {
            values.append((value * 1e9).rounded() / 1e9)
            value += step
        }
        return values
    }

    /// Short labels: no float noise, trailing zeros trimmed, a real minus sign.
    public static func format(_ value: Double) -> String {
        let rounded = (value * 1e6).rounded() / 1e6
        var text = String(format: "%.6f", abs(rounded))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return rounded < 0 ? "−" + text : text
    }
}
