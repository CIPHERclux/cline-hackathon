import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Mark selection (§6.2 b)")
struct MarkSelectionTests {
    @Test("overlapping candidates collapse to one mark, text winning over a box")
    func nonMaximumSuppression() {
        let marks = MarkSelection.selectMarks(from: [
            Candidate(kind: .box, box: CGRect(x: 100, y: 100, width: 80, height: 30)),
            Candidate(
                kind: .text, text: "Export", box: CGRect(x: 102, y: 101, width: 78, height: 29)),
        ])
        #expect(marks.count == 1)
        #expect(marks.first?.kind == .text)
    }

    @Test("the text cap leaves room for icons (D40: text used to fill the whole cap)")
    func textCapKeepsRoomForIcons() {
        var candidates: [Candidate] = (0..<300).map { index in
            Candidate(
                kind: .text, text: "label \(index)",
                box: CGRect(
                    x: Double(index % 20) * 100, y: Double(index / 20) * 40, width: 60, height: 20))
        }
        candidates += (0..<30).map { index in
            Candidate(
                kind: .shape, box: CGRect(x: Double(index) * 60, y: 2000, width: 30, height: 30))
        }
        let marks = MarkSelection.selectMarks(
            from: candidates, limits: .init(maximumMarks: 120, maximumTextMarks: 90))
        #expect(marks.count == 120)
        #expect(marks.filter { $0.kind == .text }.count == 90)
        #expect(marks.filter { $0.kind == .shape }.count == 30)
    }

    @Test("glyph outlines inside a text label and inner strokes inside an icon are dropped")
    func containedShapesDropped() {
        let marks = MarkSelection.selectMarks(from: [
            Candidate(kind: .text, text: "Save", box: CGRect(x: 0, y: 0, width: 80, height: 24)),
            Candidate(kind: .shape, box: CGRect(x: 4, y: 4, width: 18, height: 18)),
            Candidate(kind: .shape, box: CGRect(x: 300, y: 0, width: 60, height: 60)),
            Candidate(kind: .shape, box: CGRect(x: 310, y: 10, width: 30, height: 30)),
        ])
        #expect(marks.count == 2)
        #expect(marks.map(\.box.width).sorted() == [60, 80])
    }

    @Test("ids follow reading order: top-to-bottom, then left-to-right")
    func readingOrderIdentifiers() {
        let marks = MarkSelection.selectMarks(from: [
            Candidate(kind: .text, text: "C", box: CGRect(x: 10, y: 200, width: 40, height: 20)),
            Candidate(kind: .text, text: "B", box: CGRect(x: 300, y: 5, width: 40, height: 20)),
            Candidate(kind: .text, text: "A", box: CGRect(x: 10, y: 8, width: 40, height: 20)),
        ])
        #expect(marks.map(\.text) == ["A", "B", "C"])
        #expect(marks.map(\.id) == [1, 2, 3])
    }

    @Test("when the cap bites, candidates in the frontmost window win")
    func focusWindowPriority() {
        let insideWindow = CGRect(x: 1000, y: 0, width: 800, height: 800)
        let candidates =
            (0..<10).map { index in
                Candidate(
                    kind: .text, text: "outside \(index)",
                    box: CGRect(x: Double(index) * 50, y: 0, width: 40, height: 20))
            }
            + (0..<10).map { index in
                Candidate(
                    kind: .text, text: "inside \(index)",
                    box: CGRect(x: 1000 + Double(index) * 50, y: 100, width: 40, height: 20))
            }
        let marks = MarkSelection.selectMarks(
            from: candidates, limits: .init(maximumMarks: 10, maximumTextMarks: 10),
            focusRect: insideWindow)
        #expect(marks.allSatisfy { $0.text?.hasPrefix("inside") == true })
    }

    @Test("snap picks the smallest control-sized mark under the point")
    func snapToSmallestMark() {
        let marks = [
            Mark(id: 1, kind: .box, text: nil, box: CGRect(x: 0, y: 0, width: 900, height: 900)),
            Mark(id: 2, kind: .box, text: nil, box: CGRect(x: 90, y: 90, width: 200, height: 60)),
            Mark(
                id: 3, kind: .text, text: "Export",
                box: CGRect(x: 100, y: 100, width: 70, height: 20)),
        ]
        #expect(MarkSelection.smallestMark(containing: CGPoint(x: 120, y: 110), in: marks)?.id == 3)
        #expect(MarkSelection.smallestMark(containing: CGPoint(x: 250, y: 120), in: marks)?.id == 2)
        #expect(MarkSelection.smallestMark(containing: CGPoint(x: 600, y: 600), in: marks) == nil)
    }

    @Test("prompt list uses model-pixel centres")
    func promptList() {
        let space = ScreenSpace(
            displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982),
            nativePixelSize: CGSize(width: 3024, height: 1964),
            modelPixelSize: CGSize(width: 1512, height: 982))
        let list = MarkSelection.promptList(
            for: [
                Mark(
                    id: 7, kind: .text, text: "Auto \"layout\"",
                    box: CGRect(x: 200, y: 100, width: 100, height: 40))
            ],
            screenSpace: space)
        #expect(list == #"m7 text "Auto 'layout'" (125,60)"#)
    }

    @Test("marks encode their box as [x, y, width, height]")
    func markCodingFormat() throws {
        let data = try JSONEncoder().encode(
            Mark(id: 1, kind: .shape, text: nil, box: CGRect(x: 1, y: 2, width: 3, height: 4)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["box"] as? [Double] == [1, 2, 3, 4])
        #expect(
            try JSONDecoder().decode(Mark.self, from: data).box
                == CGRect(x: 1, y: 2, width: 3, height: 4))
    }
}
