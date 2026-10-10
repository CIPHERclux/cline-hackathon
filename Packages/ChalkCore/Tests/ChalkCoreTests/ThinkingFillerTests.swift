import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Thinking fillers (D63)")
struct ThinkingFillerTests {
    @Test("the prompt carries the question and the text near the pointer, and forbids answering")
    func prompt() {
        let prompt = ThinkingFiller.prompt(
            question: "solve this step by step",
            nearbyText: "2. Find the Fourier transform of f(x)",
            isWorkedSolution: true)
        #expect(prompt.contains("solve this step by step"))
        #expect(prompt.contains("Find the Fourier transform"))
        #expect(prompt.contains("Do not answer"))
    }

    @Test("the first speak line is taken, anchors stripped; code fences are tolerated")
    func spokenLine() {
        let reply =
            "```json\n"
            + #"{"type":"speak","text":"A Fourier transform of a {a1}piecewise function. Let's set it up."}"#
            + "\n```\n" + #"{"type":"end"}"#
        #expect(
            ThinkingFiller.spokenLine(fromReply: reply)
                == "A Fourier transform of a piecewise function. Let's set it up.")
    }

    @Test("long or empty replies are not spoken")
    func rejectsBadReplies() {
        let long = Array(repeating: "word", count: 45).joined(separator: " ")
        #expect(ThinkingFiller.spokenLine(fromReply: #"{"type":"speak","text":"\#(long)"}"#) == nil)
        #expect(ThinkingFiller.spokenLine(fromReply: #"{"type":"end"}"#) == nil)
    }

    @Test("text near the pointer: reading order, inside the area, capped")
    func nearbyText() {
        let marks = [
            Mark(
                id: 1, kind: .text, text: "Hence evaluate",
                box: CGRect(x: 100, y: 300, width: 200, height: 30)),
            Mark(
                id: 2, kind: .text, text: "2. Find the Fourier transform",
                box: CGRect(x: 100, y: 200, width: 400, height: 30)),
            Mark(
                id: 3, kind: .text, text: "Far away",
                box: CGRect(x: 2800, y: 1800, width: 100, height: 30)),
            Mark(id: 4, kind: .box, text: nil, box: CGRect(x: 120, y: 210, width: 50, height: 50)),
        ]
        let text = ThinkingFiller.nearbyText(
            marks: marks, within: CGRect(x: 0, y: 0, width: 1500, height: 1000),
            maximumCharacters: 200)
        #expect(text == "2. Find the Fourier transform / Hence evaluate")
    }
}
