import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Learner lasso (§4.2.5)")
struct LassoClassifierTests {
    /// A hand-drawn loop: a circle of `radius` around `center`, `turns` of the way round.
    static func loop(center: CGPoint, radius: CGFloat, turns: CGFloat = 1.05) -> [CGPoint] {
        (0...40).map { step in
            let angle = CGFloat(step) / 40 * turns * 2 * .pi
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    @Test("a closed loop is a lasso whose region is its bounds")
    func closedLoopIsLasso() {
        let stroke = LassoClassifier.classify([
            Self.loop(center: CGPoint(x: 200, y: 150), radius: 50)
        ])
        #expect(stroke?.kind == .lasso)
        let bounds = stroke?.region ?? .zero
        #expect(abs(bounds.minX - 150) < 1 && abs(bounds.maxX - 250) < 1)
        #expect(abs(bounds.minY - 100) < 1 && abs(bounds.maxY - 200) < 1)
    }

    @Test("an open stroke (an underline, a half circle) marks an area, not a lasso")
    func openStrokeIsArea() {
        let underline = (0...20).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 300) }
        #expect(LassoClassifier.classify([underline])?.kind == .area)
        let halfCircle = Self.loop(center: CGPoint(x: 200, y: 150), radius: 60, turns: 0.5)
        #expect(LassoClassifier.classify([halfCircle])?.kind == .area)
    }

    @Test("an underline's area keeps some height, so its crop shows the text above it")
    func underlineAreaHasHeight() {
        let underline = (0...20).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 300) }
        let region = LassoClassifier.classify([underline])?.region ?? .zero
        #expect(region.height >= LassoClassifier.minimumRegionSideInPoints)
        #expect(region.maxY >= 300)
    }

    @Test("tiny strokes and clicks are ignored")
    func tinyStrokesIgnored() {
        #expect(LassoClassifier.classify([[CGPoint(x: 10, y: 10)]]) == nil)
        let jitter = (0...6).map { CGPoint(x: 10 + CGFloat($0 % 2) * 3, y: 10 + CGFloat($0) * 0.5) }
        #expect(LassoClassifier.classify([jitter]) == nil)
        #expect(LassoClassifier.classify([]) == nil)
    }

    @Test("several strokes in one press: any loop makes a lasso around all of them")
    func severalStrokes() {
        let loop = Self.loop(center: CGPoint(x: 200, y: 150), radius: 40)
        let line = (0...10).map { CGPoint(x: 300 + CGFloat($0) * 10, y: 400) }
        let stroke = LassoClassifier.classify([loop, line])
        #expect(stroke?.kind == .lasso)
        #expect((stroke?.region.maxX ?? 0) >= 400)
    }
}
