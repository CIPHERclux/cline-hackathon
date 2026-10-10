import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Geometry figure (§4.2.3, D59)")
struct GeometryFigureTests {
    static let triangleJSON = JSONValue.parse(
        #"{"title":"Right triangle","points":{"A":[0,0],"B":[4,0],"C":[0,3]},"segments":[{"from":"A","to":"B","label":"4"},{"from":"B","to":"C","label":"5"},["C","A"]],"angles":[{"at":"A","right":true},{"at":"B","label":"θ"}]}"#
    )!

    @Test("points (object or list), segments (objects or pairs) and angles parse")
    func parses() throws {
        let spec = try #require(GeometrySpec(json: Self.triangleJSON))
        #expect(spec.points.map(\.name).sorted() == ["A", "B", "C"])
        #expect(spec.segments.count == 3)
        #expect(spec.segments[0].label == "4")
        #expect(spec.segments[2].from == "C" && spec.segments[2].to == "A")
        #expect(spec.angles.count == 2 && spec.angles[0].isRight)
        // Part 0 is the whole shape; each angle is a part after it.
        #expect(spec.partCount == 3)
    }

    @Test("a polygon list closes into segments; unknown point names are dropped")
    func polygon() throws {
        let spec = try #require(
            GeometrySpec(
                json: JSONValue.parse(
                    #"{"points":[{"name":"P","x":0,"y":0},{"name":"Q","x":2,"y":0},{"name":"R","x":1,"y":2}],"polygon":["P","Q","R"],"segments":[["P","Z"]]}"#
                )!))
        #expect(spec.segments.map { "\($0.from)\($0.to)" } == ["PQ", "QR", "RP"])
    }

    @Test("needs two points and one segment")
    func needsShape() {
        #expect(GeometrySpec(json: JSONValue.parse(#"{"points":{"A":[0,0]}}"#)!) == nil)
    }

    @Test("the shape fits the board, y up, keeping its proportions")
    func fitsBoard() throws {
        let spec = try #require(GeometrySpec(json: Self.triangleJSON))
        let layout = GeometryLayout.layout(spec, in: CGSize(width: 500, height: 300), padding: 50)
        let a = try #require(layout.positions["A"])
        let b = try #require(layout.positions["B"])
        let c = try #require(layout.positions["C"])
        // A is bottom-left, B right of it, C above it (smaller y on screen).
        #expect(a.y == b.y && b.x > a.x && c.y < a.y && abs(c.x - a.x) < 0.001)
        // 4:3 kept: the 3 units of height take the 200 pt available, so 4 units take 266.7.
        #expect(abs((b.x - a.x) / (a.y - c.y) - 4.0 / 3.0) < 0.001)
        for point in [a, b, c] {
            #expect(point.x >= 50 && point.x <= 450 && point.y >= 50 && point.y <= 250)
        }
    }

    @Test("vertex labels sit outside the shape; side labels outside their side")
    func labelsOutside() throws {
        let spec = try #require(GeometrySpec(json: Self.triangleJSON))
        let layout = GeometryLayout.layout(spec, in: CGSize(width: 500, height: 300), padding: 50)
        let centroid = layout.centroid
        for (name, labelPoint) in layout.pointLabelPositions {
            let vertex = layout.positions[name]!
            #expect(
                hypot(labelPoint.x - centroid.x, labelPoint.y - centroid.y)
                    > hypot(vertex.x - centroid.x, vertex.y - centroid.y))
        }
        // AB is the bottom side: its label goes below it.
        #expect(layout.segmentLabelPositions[0]!.y > layout.positions["A"]!.y)
    }

    @Test("an angle mark sits at its vertex, between its two sides")
    func angleMark() throws {
        let spec = try #require(GeometrySpec(json: Self.triangleJSON))
        let layout = GeometryLayout.layout(spec, in: CGSize(width: 500, height: 300), padding: 50)
        let right = layout.angleMarks[0]
        #expect(right.vertex == layout.positions["A"])
        #expect(right.isRight)
        // At A the sides go right (0) and up (−π/2 on screen): the mark spans those directions.
        let directions = [right.startAngle, right.endAngle].map { ($0 * 180 / .pi).rounded() }
            .sorted()
        #expect(directions == [-90, 0])
    }

    @Test("regular: n makes an n-gon named A, B, C… with a flat bottom side")
    func regularPolygon() throws {
        let spec = try #require(
            GeometrySpec(
                json: JSONValue.parse(
                    #"{"title":"Hexagon","regular":6,"angles":[{"at":"A","label":"120°"}]}"#)!))
        #expect(spec.points.map(\.name) == ["A", "B", "C", "D", "E", "F"])
        #expect(spec.segments.count == 6)
        #expect(spec.segments.last?.from == "F" && spec.segments.last?.to == "A")
        #expect(spec.angles.first?.label == "120°")
        // A and B share the lowest y: the bottom side is horizontal.
        let a = spec.points[0]
        let b = spec.points[1]
        #expect(abs(a.y - b.y) < 1e-9)
        #expect(spec.points.allSatisfy { $0.y >= a.y - 1e-9 })
    }

    @Test("regular is clamped to 3…12 sides")
    func regularClamped() throws {
        let spec = try #require(GeometrySpec(json: JSONValue.parse(#"{"regular":40}"#)!))
        #expect(spec.points.count == 12)
    }
}

@Suite("Figure hint for shape requests (§7.4-style deterministic rule, D60)")
struct FigureHintTests {
    @Test("asking to draw or show a shape gets the geometry hint")
    func shapeRequests() {
        #expect(FigureHint.forQuestion("Can you draw a hexagon?") == .geometry)
        #expect(FigureHint.forQuestion("show me a right triangle and its angles") == .geometry)
        #expect(FigureHint.forQuestion("Sketch a square with its diagonals") == .geometry)
    }

    @Test("questions that only mention shapes, or ask for other drawings, get none")
    func otherQuestions() {
        #expect(FigureHint.forQuestion("What is the area of a triangle with base 4?") == nil)
        #expect(FigureHint.forQuestion("Draw a circle around the play button") == nil)
        #expect(FigureHint.forQuestion("Why does 0.999 equal 1?") == nil)
    }
}
