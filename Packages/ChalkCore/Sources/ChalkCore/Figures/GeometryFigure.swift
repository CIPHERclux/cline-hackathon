import CoreGraphics
import Foundation

/// `{"title":…,"points":{"A":[0,0],…} | [{"name":"A","x":0,"y":0}],
///   "segments":[{"from":"A","to":"B","label":"4"} | ["A","B"]], "polygon":["A","B","C"],
///   "angles":[{"at":"A","label":"90°","right":true}]}`. Coordinates are any units, y up (D59).
/// `"regular": n` makes a regular n-gon named A, B, C… with a flat bottom side, so the model
/// needn't compute coordinates (D60).
public struct GeometrySpec: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var name: String
        public var x: Double
        public var y: Double
    }

    public struct Segment: Equatable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
    }

    public struct Angle: Equatable, Sendable {
        public var vertex: String
        public var label: String?
        public var isRight: Bool
    }

    static let maximumElements = 16

    public var title: String?
    public var points: [Point]
    public var segments: [Segment]
    public var angles: [Angle]

    public init?(json: JSONValue) {
        var points: [Point] = []
        if case .object(let dictionary) = json["points"] {
            for (name, value) in dictionary.sorted(by: { $0.key < $1.key }) {
                guard let coordinates = value.arrayValue, coordinates.count == 2,
                    let x = coordinates[0].numberValue, let y = coordinates[1].numberValue
                else { continue }
                points.append(Point(name: name, x: x, y: y))
            }
        } else {
            points = (json["points"]?.arrayValue ?? []).compactMap {
                guard let name = $0["name"]?.stringValue, let x = $0["x"]?.numberValue,
                    let y = $0["y"]?.numberValue
                else { return nil }
                return Point(name: name, x: x, y: y)
            }
        }
        var segments: [Segment] = []
        if points.isEmpty, let sides = json["regular"]?.integerValue {
            let count = min(max(sides, 3), 12)
            let letters = Array("ABCDEFGHIJKL")
            // Start at the bottom-left vertex so A–B is a horizontal bottom side.
            let start = -Double.pi / 2 - Double.pi / Double(count)
            for index in 0..<count {
                let angle = start + Double(index) * 2 * .pi / Double(count)
                points.append(Point(name: String(letters[index]), x: cos(angle), y: sin(angle)))
            }
            for index in 0..<count {
                segments.append(
                    Segment(
                        from: points[index].name, to: points[(index + 1) % count].name, label: nil))
            }
        }
        let names = Set(points.map(\.name))
        if let polygon = json["polygon"]?.arrayValue?.compactMap(\.stringValue), polygon.count >= 2
        {
            for (index, name) in polygon.enumerated() {
                segments.append(
                    Segment(from: name, to: polygon[(index + 1) % polygon.count], label: nil))
            }
        }
        for segmentJSON in json["segments"]?.arrayValue ?? [] {
            if let pair = segmentJSON.arrayValue?.compactMap(\.stringValue), pair.count == 2 {
                segments.append(Segment(from: pair[0], to: pair[1], label: nil))
            } else if let from = segmentJSON["from"]?.stringValue,
                let to = segmentJSON["to"]?.stringValue
            {
                segments.append(
                    Segment(from: from, to: to, label: segmentJSON["label"]?.stringValue))
            }
        }
        segments = segments.filter {
            names.contains($0.from) && names.contains($0.to) && $0.from != $0.to
        }
        let angles = (json["angles"]?.arrayValue ?? []).compactMap { angleJSON -> Angle? in
            guard let vertex = angleJSON["at"]?.stringValue, names.contains(vertex) else {
                return nil
            }
            let isRight: Bool
            if case .bool(let flag) = angleJSON["right"] { isRight = flag } else { isRight = false }
            return Angle(vertex: vertex, label: angleJSON["label"]?.stringValue, isRight: isRight)
        }
        guard points.count >= 2, !segments.isEmpty else { return nil }
        self.title = json["title"]?.stringValue
        self.points = points
        self.segments = Array(segments.prefix(Self.maximumElements))
        self.angles = Array(angles.prefix(Self.maximumElements))
    }

    /// Part 0 is the whole shape (every segment); each angle is a part after it.
    public var partCount: Int { 1 + angles.count }
}

/// Fits a geometry figure into the board (uniform scale, centred, y flipped to screen space)
/// and places labels outside the shape. Pure; the whiteboard draws what this returns.
public struct GeometryLayout: Equatable, Sendable {
    public struct AngleMark: Equatable, Sendable {
        public var vertex: CGPoint
        /// Screen angles (radians, y down) of the two sides, the arc going the short way.
        public var startAngle: CGFloat
        public var endAngle: CGFloat
        public var radius: CGFloat
        public var isRight: Bool
        public var label: String?
        public var labelPosition: CGPoint
    }

    public var positions: [String: CGPoint]
    public var centroid: CGPoint
    public var pointLabelPositions: [String: CGPoint]
    /// Keyed by segment index.
    public var segmentLabelPositions: [Int: CGPoint]
    public var angleMarks: [AngleMark]

    public static let pointLabelGap: CGFloat = 18
    public static let segmentLabelGap: CGFloat = 16
    public static let angleRadius: CGFloat = 22

    public static func layout(_ spec: GeometrySpec, in size: CGSize, padding: CGFloat)
        -> GeometryLayout
    {
        let xs = spec.points.map(\.x)
        let ys = spec.points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 1
        let spanX = max(maxX - minX, 1e-9)
        let spanY = max(maxY - minY, 1e-9)
        let availableWidth = max(size.width - 2 * padding, 1)
        let availableHeight = max(size.height - 2 * padding, 1)
        let scale = min(availableWidth / CGFloat(spanX), availableHeight / CGFloat(spanY))
        let offsetX = padding + (availableWidth - CGFloat(spanX) * scale) / 2
        let offsetY = padding + (availableHeight - CGFloat(spanY) * scale) / 2
        var positions: [String: CGPoint] = [:]
        for point in spec.points {
            positions[point.name] = CGPoint(
                x: offsetX + CGFloat(point.x - minX) * scale,
                y: offsetY + CGFloat(maxY - point.y) * scale)
        }
        let all = Array(positions.values)
        let centroid = CGPoint(
            x: all.map(\.x).reduce(0, +) / CGFloat(all.count),
            y: all.map(\.y).reduce(0, +) / CGFloat(all.count))
        func away(from origin: CGPoint, point: CGPoint, by gap: CGFloat) -> CGPoint {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            let length = max(hypot(dx, dy), 1e-6)
            return CGPoint(x: point.x + dx / length * gap, y: point.y + dy / length * gap)
        }
        var pointLabels: [String: CGPoint] = [:]
        for (name, position) in positions {
            pointLabels[name] = away(from: centroid, point: position, by: pointLabelGap)
        }
        var segmentLabels: [Int: CGPoint] = [:]
        for (index, segment) in spec.segments.enumerated() {
            guard let from = positions[segment.from], let to = positions[segment.to] else {
                continue
            }
            let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            // The side's normal that points away from the centroid.
            var normal = CGPoint(x: -(to.y - from.y), y: to.x - from.x)
            let length = max(hypot(normal.x, normal.y), 1e-6)
            normal = CGPoint(x: normal.x / length, y: normal.y / length)
            if (middle.x - centroid.x) * normal.x + (middle.y - centroid.y) * normal.y < 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
            segmentLabels[index] = CGPoint(
                x: middle.x + normal.x * segmentLabelGap, y: middle.y + normal.y * segmentLabelGap)
        }
        var angleMarks: [AngleMark] = []
        for angle in spec.angles {
            guard let vertex = positions[angle.vertex] else { continue }
            let neighbours = spec.segments.compactMap { segment -> CGPoint? in
                if segment.from == angle.vertex { return positions[segment.to] }
                if segment.to == angle.vertex { return positions[segment.from] }
                return nil
            }
            guard neighbours.count >= 2 else { continue }
            var start = atan2(neighbours[0].y - vertex.y, neighbours[0].x - vertex.x)
            var end = atan2(neighbours[1].y - vertex.y, neighbours[1].x - vertex.x)
            if end - start > .pi { end -= 2 * .pi } else if start - end > .pi { start -= 2 * .pi }
            let bisector = (start + end) / 2
            angleMarks.append(
                AngleMark(
                    vertex: vertex, startAngle: start, endAngle: end, radius: angleRadius,
                    isRight: angle.isRight, label: angle.label,
                    labelPosition: CGPoint(
                        x: vertex.x + cos(bisector) * (angleRadius + 14),
                        y: vertex.y + sin(bisector) * (angleRadius + 14))))
        }
        return GeometryLayout(
            positions: positions, centroid: centroid, pointLabelPositions: pointLabels,
            segmentLabelPositions: segmentLabels, angleMarks: angleMarks)
    }
}
