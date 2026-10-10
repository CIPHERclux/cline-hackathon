import CoreGraphics
import Foundation

/// What Chalk says while the main model is still thinking (D63). The owner asked to keep
/// reasoning on (accuracy) and fill the wait (Sonnet took ~15 s to its first words on a worked
/// solution) with lines about the question itself rather than generic stalling. A fast-slot call
/// writes one such line from the question and the text near the pointer, without answering it.
public enum ThinkingFiller {
    /// Longer than this, it isn't a filler any more.
    static let maximumWords = 22

    public static func prompt(question: String, nearbyText: String?, isWorkedSolution: Bool)
        -> String
    {
        let screenLine = nearbyText.map { "\nText on screen near their pointer: \"\($0)\"" } ?? ""
        let plan =
            isWorkedSolution
            ? "say you'll work through it on the board step by step"
            : "say what you're about to look at or explain"
        return """
            The learner just asked: "\(question)"\(screenLine)
            Another teacher is preparing the full answer, which takes a few seconds. Write the \
            one thing a good teacher says while getting ready: show you understood what they asked \
            (name the kind of task in a few plain words, nothing specific you might get wrong) \
            and \(plan). 8 to 16 words, warm and natural, no greeting, and don't start with "Okay", "Sure", "Got it" or "I'll": start \
            with the topic itself ("A Fourier transform of a piecewise function…"). Do not answer, \
            solve, hint at the result or give any numbers.
            Reply with exactly one line {"type":"speak","text":"…"} and then {"type":"end"}.
            """
    }

    /// The first speak line of the reply, anchors stripped; nil when missing or too long.
    public static func spokenLine(fromReply reply: String) -> String? {
        var parser = StreamingScriptParser()
        let events = parser.feed(reply + "\n") + parser.finish()
        for event in events {
            guard case .action(.speak(let speak)) = event else { continue }
            let text = AnchorMapper.map(speak.text).spokenText.trimmingCharacters(in: .whitespaces)
            let wordCount = text.split(separator: " ").count
            return wordCount > 0 && wordCount <= maximumWords ? text : nil
        }
        return nil
    }

    /// OCR'd lines inside `area` (native pixels) in reading order, joined, capped.
    public static func nearbyText(marks: [Mark], within area: CGRect, maximumCharacters: Int = 400)
        -> String?
    {
        let lines = marks.filter { $0.kind == .text && area.contains($0.center) }
            .sorted {
                abs($0.box.minY - $1.box.minY) > 8
                    ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX
            }
            .compactMap(\.text)
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: " / ")
        return joined.count <= maximumCharacters
            ? joined : String(joined.prefix(maximumCharacters)) + "…"
    }
}
