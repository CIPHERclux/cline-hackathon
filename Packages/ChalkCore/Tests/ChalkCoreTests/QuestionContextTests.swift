import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Question context (D62)")
struct QuestionContextTests {
    @Test("solve / step by step / evaluate / derive are worked-solution requests")
    func workedSolutions() {
        #expect(
            QuestionContext.isWorkedSolution("Can you help me solve this question step by step?"))
        #expect(QuestionContext.isWorkedSolution("evaluate this integral"))
        #expect(QuestionContext.isWorkedSolution("Work out the answer to number 2"))
        #expect(QuestionContext.isWorkedSolution("show me the steps"))
        #expect(!QuestionContext.isWorkedSolution("Where's the play button?"))
        #expect(!QuestionContext.isWorkedSolution("What does this word mean?"))
    }

    @Test("the pointer is given in 0–1000 screenshot coordinates")
    func pointerLine() {
        let screenSpace = ScreenSpace(
            displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982),
            nativePixelSize: CGSize(width: 3024, height: 1964),
            modelPixelSize: CGSize(width: 1568, height: 1018))
        let line = QuestionContext.pointerLine(
            cursorInNativePixels: CGPoint(x: 1512, y: 491), screenSpace: screenSpace)
        #expect(line.contains("(500, 250)"))
        #expect(line.contains("this question"))
    }

    @Test("the crop around the pointer is 760×520 pt, inside the display")
    func cropAroundPointer() {
        let screenSpace = ScreenSpace(
            displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982),
            nativePixelSize: CGSize(width: 3024, height: 1964),
            modelPixelSize: CGSize(width: 1568, height: 1018))
        let crop = QuestionContext.cropAroundPointer(
            cursorInNativePixels: CGPoint(x: 100, y: 100), screenSpace: screenSpace)
        #expect(crop == CGRect(x: 0, y: 0, width: 1520, height: 1040))
    }
}
