import Foundation

/// The declarative figure specs the model writes (§4.2.3: "the model never emits pixels or
/// SVG"). The spec leaves the fields open; these are the demo's, kept forgiving (D56).

/// `{"min":0,"max":1,"ticks":[…] | "step":0.1,"marks":[{"value":0.5,"label":"½"}],
///   "intervals":[{"from":0.2,"to":0.4,"label":"gap"}]}`. A mark's position may be `at`.
public struct NumberLineSpec: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public var value: Double
        public var label: String?

        public init(value: Double, label: String? = nil) {
            self.value = value
            self.label = label
        }
    }

    public struct Interval: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var label: String?

        public init(from: Double, to: Double, label: String? = nil) {
            self.from = from
            self.to = to
            self.label = label
        }
    }

    /// More would be unreadable on a whiteboard; extras are dropped.
    static let maximumElements = 12

    public var minimum: Double
    public var maximum: Double
    public var ticks: [Double]?
    public var step: Double?
    public var marks: [Mark]
    public var intervals: [Interval]

    public init(
        minimum: Double, maximum: Double, ticks: [Double]? = nil, step: Double? = nil,
        marks: [Mark] = [], intervals: [Interval] = []
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.ticks = ticks
        self.step = step
        self.marks = marks
        self.intervals = intervals
    }

    public init?(json: JSONValue) {
        guard let minimum = json["min"]?.numberValue, let maximum = json["max"]?.numberValue,
            maximum > minimum
        else { return nil }
        let ticks = json["ticks"]?.arrayValue?.compactMap(\.numberValue).filter {
            $0 >= minimum && $0 <= maximum
        }
        let marks = (json["marks"]?.arrayValue ?? []).compactMap { markJSON -> Mark? in
            guard let value = markJSON["value"]?.numberValue ?? markJSON["at"]?.numberValue else {
                return nil
            }
            return Mark(value: value, label: markJSON["label"]?.stringValue)
        }
        let intervals = (json["intervals"]?.arrayValue ?? []).compactMap {
            intervalJSON -> Interval? in
            guard let from = intervalJSON["from"]?.numberValue,
                let to = intervalJSON["to"]?.numberValue
            else { return nil }
            return Interval(
                from: min(from, to), to: max(from, to), label: intervalJSON["label"]?.stringValue)
        }
        self.init(
            minimum: minimum, maximum: maximum, ticks: ticks?.isEmpty == false ? ticks : nil,
            step: json["step"]?.numberValue.flatMap { $0 > 0 ? $0 : nil },
            marks: Array(marks.prefix(Self.maximumElements)),
            intervals: Array(intervals.prefix(Self.maximumElements)))
    }

    /// Parts for progressive reveal (§4.2.4): marks, then intervals; part 0 shows with the axis.
    public var partCount: Int { marks.count + intervals.count }
}

/// `{"title":"…","steps":["x = 0.999…","10x = 9.999…"]}`. Lines are plain text with Unicode
/// math (D25: no LaTeX renderer in the demo); `{"text":…}` objects are accepted too.
public struct MathStepsSpec: Equatable, Sendable {
    /// Worked solutions show every intermediate step (D65); the board scrolls to follow them.
    static let maximumSteps = 24

    public var title: String?
    public var steps: [String]

    public init(title: String? = nil, steps: [String]) {
        self.title = title
        self.steps = steps
    }

    public init?(json: JSONValue) {
        let lines = (json["steps"]?.arrayValue ?? json["lines"]?.arrayValue ?? []).compactMap {
            ($0.stringValue ?? $0["text"]?.stringValue).map(Self.repairingLatexEscapes)?
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        self.init(title: json["title"]?.stringValue, steps: Array(lines.prefix(Self.maximumSteps)))
    }

    /// LaTeX written into JSON with single backslashes arrives as control characters: `\frac`
    /// becomes form feed + "rac", `\text` tab + "ext", `\beta` backspace + "eta". Put the
    /// backslashes back (D61).
    static func repairingLatexEscapes(_ line: String) -> String {
        let repairs: [(Character, String)] = [
            ("\u{0C}", "\\f"), ("\u{09}", "\\t"), ("\u{08}", "\\b"), ("\r", "\\r"), ("\n", "\\n"),
        ]
        var repaired = ""
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if let replacement = repairs.first(where: { $0.0 == character })?.1,
                characters.first?.isLetter == true
            {
                repaired += replacement
            } else {
                repaired.append(character)
            }
        }
        return repaired
    }

    /// One part per line; line 0 shows with the figure.
    public var partCount: Int { steps.count }
}
