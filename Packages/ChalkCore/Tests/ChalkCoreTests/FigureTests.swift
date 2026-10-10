import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Figure specs (§4.2.3, D56)")
struct FigureSpecTests {
    static func json(_ text: String) -> JSONValue {
        JSONValue.parse(text)!
    }

    @Test("a numberline spec reads range, ticks, marks (value or at) and intervals")
    func numberLine() throws {
        let spec = try #require(
            NumberLineSpec(
                json: Self.json(
                    #"{"min":0.9,"max":1,"ticks":[0.9,0.99,1],"marks":[{"value":0.999,"label":"0.999…"},{"at":1}],"intervals":[{"from":0.999,"to":1,"label":"gap"}]}"#
                )))
        #expect(spec.minimum == 0.9 && spec.maximum == 1)
        #expect(spec.ticks == [0.9, 0.99, 1])
        #expect(spec.marks.map(\.value) == [0.999, 1])
        #expect(spec.marks.first?.label == "0.999…")
        #expect(spec.intervals.first?.label == "gap")
        #expect(spec.partCount == 3)
    }

    @Test("a numberline needs max > min")
    func numberLineNeedsRange() {
        #expect(NumberLineSpec(json: Self.json(#"{"min":1,"max":1}"#)) == nil)
        #expect(NumberLineSpec(json: Self.json(#"{"max":3}"#)) == nil)
    }

    @Test("math steps accept plain strings or {text} objects, and drop empty lines")
    func mathSteps() throws {
        let plain = try #require(
            MathStepsSpec(json: Self.json(#"{"steps":["x = 0.999…","10x = 9.999…",""]}"#)))
        #expect(plain.steps == ["x = 0.999…", "10x = 9.999…"])
        let objects = try #require(
            MathStepsSpec(
                json: Self.json(#"{"title":"Why","steps":[{"text":"a = b"},{"text":"b = a"}]}"#)))
        #expect(objects.steps.count == 2)
        #expect(objects.title == "Why")
        #expect(MathStepsSpec(json: Self.json(#"{"steps":[]}"#)) == nil)
    }

    @Test("the validator accepts numberline and math_steps figures only")
    func validatorScope() {
        var parser = StreamingScriptParser()
        let events =
            parser.feed(
                #"{"type":"figure","kind":"numberline","spec":{"min":0,"max":1}}"# + "\n"
                    + #"{"type":"figure","kind":"plot","spec":{}}"# + "\n") + parser.finish()
        let figures = events.compactMap { event -> FigureKind? in
            if case .action(.figure(let figure)) = event { return figure.kind }
            return nil
        }
        #expect(figures == [.numberline])
        #expect(events.contains(.diagnostic(.outOfDemoScope("figure:plot"))))
    }
}

@Suite("Number line layout (§4.2.3)")
struct NumberLineLayoutTests {
    @Test("ticks are placed linearly between the padded ends")
    func linearTicks() {
        let spec = NumberLineSpec(minimum: 0, maximum: 10, ticks: [0, 5, 10])
        let layout = NumberLineLayout.layout(spec, width: 248, padding: 24)
        #expect(layout.axisStartX == 24 && layout.axisEndX == 224)
        #expect(layout.ticks.map(\.x) == [24, 124, 224])
    }

    @Test("without ticks, a nice 1-2-5 step is chosen")
    func niceSteps() {
        #expect(NumberLineLayout.niceTickStep(range: 10) == 1)
        #expect(NumberLineLayout.niceTickStep(range: 1) == 0.1)
        #expect(NumberLineLayout.niceTickStep(range: 0.1) == 0.01)
        #expect(NumberLineLayout.niceTickStep(range: 40) == 5)
        let layout = NumberLineLayout.layout(
            NumberLineSpec(minimum: 0, maximum: 1), width: 500, padding: 20)
        #expect(layout.ticks.count == 11)
        #expect(layout.ticks.last?.label == "1")
    }

    @Test("labels are short: no float noise, trailing zeros trimmed")
    func labels() {
        #expect(NumberLineLayout.format(0.30000000000000004) == "0.3")
        #expect(NumberLineLayout.format(0.999) == "0.999")
        #expect(NumberLineLayout.format(-2) == "−2")
        #expect(NumberLineLayout.format(1_000_000) == "1000000")
    }

    @Test("crowded tick labels are thinned so none overlap")
    func crowdedLabelsThinned() {
        let spec = NumberLineSpec(minimum: 0.9, maximum: 1, ticks: [0.9, 0.99, 0.999, 1])
        let layout = NumberLineLayout.layout(spec, width: 300, padding: 20, characterWidth: 7)
        let labelled = layout.ticks.filter { $0.label != nil }
        #expect(labelled.first?.value == 0.9)
        for (left, right) in zip(labelled, labelled.dropFirst()) {
            let leftEdge = left.x + CGFloat(left.label!.count) * 7 / 2
            let rightEdge = right.x - CGFloat(right.label!.count) * 7 / 2
            #expect(leftEdge <= rightEdge)
        }
    }

    @Test("marks and intervals land on their values; out-of-range marks clamp to the end")
    func marksAndIntervals() {
        let spec = NumberLineSpec(
            minimum: 0, maximum: 10, marks: [.init(value: 5, label: "half"), .init(value: 12)],
            intervals: [.init(from: 2, to: 4)])
        let layout = NumberLineLayout.layout(spec, width: 248, padding: 24)
        #expect(layout.marks[0].x == 124)
        #expect(layout.marks[1].x == 224)
        #expect(layout.marks[1].isOutOfRange)
        #expect(layout.intervals[0].fromX == 64 && layout.intervals[0].toX == 104)
    }

    @Test("labels of marks that sit close together stack instead of overlapping")
    func closeMarkLabelsStack() {
        let spec = NumberLineSpec(
            minimum: 0.9, maximum: 1,
            marks: [
                .init(value: 0.999, label: "0.999…"), .init(value: 1, label: "1"),
                .init(value: 0.92, label: "0.92"),
            ])
        let layout = NumberLineLayout.layout(spec, width: 560)
        #expect(layout.marks.map(\.labelLevel) == [0, 1, 0])
    }
}

@Suite("Math steps diff (§4.2.3)")
struct MathStepsDiffTests {
    static func changed(_ previous: String, _ line: String) -> [String] {
        MathStepsDiff.changedRanges(from: previous, to: line).map { String(line[$0]) }
    }

    @Test("x = 0.999… → 10x = 9.999…: the new 10 and 9.999… are highlighted")
    func repeatingDecimal() {
        #expect(Self.changed("x = 0.999…", "10x = 9.999…") == ["10", "9.999…"])
    }

    @Test("an unchanged line has nothing highlighted; the first line has no previous")
    func unchanged() {
        #expect(Self.changed("9x = 9", "9x = 9").isEmpty)
        #expect(MathStepsDiff.changedRanges(from: nil, to: "x = 1").isEmpty)
    }

    @Test("adjacent changed tokens merge into one span")
    func adjacentMerge() {
        #expect(Self.changed("x = 1", "x = 1 + 2") == ["+ 2"])
    }

    @Test("tokens: numbers keep decimals and ellipses; letters split from numbers")
    func tokens() {
        #expect(
            MathStepsDiff.tokens(in: "10x − x = 9.999…").map(\.text) == [
                "10", "x", "−", "x", "=", "9.999…",
            ])
    }
}
