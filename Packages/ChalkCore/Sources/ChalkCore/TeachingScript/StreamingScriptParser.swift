import Foundation

/// Turns the teaching model's streamed text deltas into validated Teaching Script actions,
/// one completed NDJSON line at a time (§6.4), so speech can start on the first `speak` line
/// while the rest of the answer is still arriving.
///
/// Recovery (§6.4 "Validation and recovery"):
/// - a line is processed only once its newline arrives; deltas may split it anywhere;
/// - 2 KB without a newline → the buffered text is spoken as plain speech;
/// - non-JSON text → plain speech (graceful degradation);
/// - code fences and trailing commas are repaired before decoding. §6.4 places this repair in
///   the sidecar; it lives here so the sidecar stays a pass-through and the repair is unit-tested
///   next to the parser (D44);
/// - JSON that still doesn't parse is dropped and counted (§11.2 malformed-rate gate).
public struct StreamingScriptParser: Sendable {
    public static let maximumBufferedBytesWithoutNewline = 2048

    public struct Statistics: Equatable, Sendable {
        public var jsonLines = 0
        public var malformedJSONLines = 0
        public var plainTextLines = 0

        /// Share of JSON-looking lines that could not be used, for the §11.2 ≤ 2% gate.
        public var malformedRate: Double {
            jsonLines == 0 ? 0 : Double(malformedJSONLines) / Double(jsonLines)
        }
    }

    public private(set) var statistics = Statistics()
    private var bufferedText = ""
    /// Off for walkthrough turns (D73): a model's stray thought ("I'll draw an ellipse around…")
    /// was read aloud. Prose is then dropped and reported instead of spoken.
    public var speaksPlainText = true

    public init(speaksPlainText: Bool = true) {
        self.speaksPlainText = speaksPlainText
    }

    /// Feeds one streamed delta; returns the events for every line it completed.
    public mutating func feed(_ delta: String) -> [ScriptEvent] {
        bufferedText += delta
        var events: [ScriptEvent] = []
        while let newlineIndex = bufferedText.firstIndex(where: \.isNewline) {
            let line = String(bufferedText[..<newlineIndex])
            bufferedText.removeSubrange(...newlineIndex)
            events += processLine(line)
        }
        let bufferedByteCount = bufferedText.utf8.count
        if bufferedByteCount > Self.maximumBufferedBytesWithoutNewline {
            events.append(.diagnostic(.overlongLineSpokenAsText(byteCount: bufferedByteCount)))
            events += speech(bufferedText)
            bufferedText = ""
        }
        return events
    }

    /// Ends the stream: a final line without a trailing newline is still processed.
    public mutating func finish() -> [ScriptEvent] {
        let remainder = bufferedText
        bufferedText = ""
        return processLine(remainder)
    }

    private mutating func processLine(_ rawLine: String) -> [ScriptEvent] {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        var events: [ScriptEvent] = []

        // ```json … ``` around the script, or glued to a line.
        if line.hasPrefix("```") {
            events.append(.diagnostic(.repaired(.codeFence)))
            line = String(line.dropFirst(3))
            for languageTag in ["ndjson", "jsonl", "json"]
            where line.lowercased().hasPrefix(languageTag) {
                line = String(line.dropFirst(languageTag.count))
                break
            }
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if line.hasSuffix("```") {
            if !events.contains(.diagnostic(.repaired(.codeFence))) {
                events.append(.diagnostic(.repaired(.codeFence)))
            }
            line = String(line.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        if line.isEmpty { return events }

        // The model wrapped the script in a JSON array, as the spec's example is shown.
        if ["[", "]", "],", "];"].contains(line) {
            return events + [.diagnostic(.repaired(.arrayBracket))]
        }

        guard line.hasPrefix("{") else { return events + speech(line) }

        statistics.jsonLines += 1
        // Repair first, always: some Foundation versions accept trailing commas and some don't,
        // and the result must not depend on the OS. Valid JSON never has a comma before } or ],
        // so this cannot damage a correct line.
        let repairedLine = Self.removingTrailingCommas(line)
        if let json = JSONValue.parse(repairedLine), json.isObject {
            let repairEvents: [ScriptEvent] =
                repairedLine != line ? [.diagnostic(.repaired(.trailingComma))] : []
            return events + repairEvents + ScriptValidator.validate(json)
        }
        statistics.malformedJSONLines += 1
        return events + [.diagnostic(.malformedJSON(line: String(line.prefix(200))))]
    }

    private mutating func speech(_ text: String) -> [ScriptEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        statistics.plainTextLines += 1
        guard speaksPlainText else {
            return [.diagnostic(.plainTextDropped(String(trimmed.prefix(200))))]
        }
        return [.action(.speak(SpeakAction(text: trimmed)))]
    }

    /// `{"a": 1,}` → `{"a": 1}`, `[1, 2,]` → `[1, 2]`, and a comma after the whole object
    /// (`{…},` from array-style output). Commas inside strings are left alone.
    static func removingTrailingCommas(_ line: String) -> String {
        var trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasSuffix(",") { trimmedLine.removeLast() }
        var result = ""
        var isInsideString = false
        var previousWasEscape = false
        var pendingComma = false
        var whitespaceAfterPendingComma = ""
        for character in trimmedLine {
            if isInsideString {
                result.append(character)
                if previousWasEscape {
                    previousWasEscape = false
                } else if character == "\\" {
                    previousWasEscape = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }
            if pendingComma {
                if character.isWhitespace {
                    whitespaceAfterPendingComma.append(character)
                    continue
                }
                if character != "}" && character != "]" { result.append(",") }
                result += whitespaceAfterPendingComma
                pendingComma = false
                whitespaceAfterPendingComma = ""
            }
            if character == "," {
                pendingComma = true
                continue
            }
            if character == "\"" { isInsideString = true }
            result.append(character)
        }
        if pendingComma { result += whitespaceAfterPendingComma }
        return result
    }
}
