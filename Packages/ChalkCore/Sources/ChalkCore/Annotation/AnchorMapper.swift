import Foundation

/// A `speak` line with its anchor markers removed (§4.2.4): what TTS says, plus where each
/// anchor sits in it, as UTF-16 offsets (the unit of `willSpeakRangeOfSpeechString` ranges).
public struct AnchoredSpeech: Equatable, Sendable {
    public var spokenText: String
    public var anchorOffsets: [String: Int]
}

public enum AnchorMapper {
    /// `Swapping {a1}this sum and {a2}this integral` → spoken "Swapping this sum and this
    /// integral", a1 → offset of "this sum", a2 → offset of "this integral".
    public static func map(_ text: String) -> AnchoredSpeech {
        var spokenText = ""
        var anchorOffsets: [String: Int] = [:]
        var remainder = Substring(text)
        while let markerStart = remainder.firstIndex(of: "{") {
            spokenText += remainder[..<markerStart]
            let afterBrace = remainder.index(after: markerStart)
            if let markerEnd = remainder[afterBrace...].firstIndex(of: "}") {
                let name = remainder[afterBrace..<markerEnd]
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    anchorOffsets[String(name)] = spokenText.utf16.count
                    remainder = remainder[remainder.index(after: markerEnd)...]
                    continue
                }
            }
            // Not a marker (a literal brace): keep it.
            spokenText += "{"
            remainder = remainder[afterBrace...]
        }
        spokenText += remainder
        return AnchoredSpeech(spokenText: spokenText, anchorOffsets: anchorOffsets)
    }
}

/// Decides when each drawing starts (§4.2.4): when the spoken word reaches its anchor, right
/// away when it has no anchor or its anchor already passed, and at the end of the utterance at the
/// latest (so a drawing is never lost when range callbacks skip a word). A drawing whose anchor
/// isn't declared yet waits for the speak line that declares it (the rules ask for drawings
/// before their sentence, so they are ready when the word plays, D50); `flushUndeclared` starts
/// the rest when the script ends. A pure state machine fed with TTS events, so recorded timing
/// replays identically (§6.4 determinism).
public struct AnchorScheduler: Sendable {
    private struct AnchorState: Sendable {
        var utteranceIdentifier: Int
        var offset: Int
        var hasFired = false
    }

    private var anchors: [String: AnchorState] = [:]
    private var pendingDrawingsByAnchor: [String: [String]] = [:]
    private var groupByUtterance: [Int: String] = [:]
    private var unfinishedUtteranceCountByGroup: [String: Int] = [:]

    public init() {}

    public mutating func utteranceQueued(
        utteranceIdentifier: Int, group: String?, anchorOffsets: [String: Int]
    ) {
        for (anchorName, offset) in anchorOffsets {
            anchors[anchorName] = AnchorState(
                utteranceIdentifier: utteranceIdentifier, offset: offset)
        }
        if let group {
            groupByUtterance[utteranceIdentifier] = group
            unfinishedUtteranceCountByGroup[group, default: 0] += 1
        }
    }

    /// A drawing arrived from the script. Returns true when it should start now; otherwise it
    /// waits for its anchor.
    public mutating func drawingArrived(markIdentifier: String, anchor: String?) -> Bool {
        guard let anchor else { return true }
        if let anchorState = anchors[anchor], anchorState.hasFired { return true }
        pendingDrawingsByAnchor[anchor, default: []].append(markIdentifier)
        return false
    }

    /// The script ended: drawings whose anchor no speak line declared start now.
    public mutating func flushUndeclared() -> [String] {
        let undeclared = pendingDrawingsByAnchor.keys.filter { anchors[$0] == nil }.sorted()
        return undeclared.flatMap { pendingDrawingsByAnchor.removeValue(forKey: $0) ?? [] }
    }

    /// TTS is about to speak `range` of the utterance. Returns the drawings to start now.
    public mutating func rangeWillBeSpoken(utteranceIdentifier: Int, range: NSRange) -> [String] {
        let wordEnd = range.location + range.length
        return fireAnchors { $0.utteranceIdentifier == utteranceIdentifier && $0.offset < wordEnd }
    }

    /// The utterance finished (or was cut). Returns drawings whose anchors never fired, and the
    /// groups that are now completely spoken (their speech-bound marks fade, §4.2.2).
    public mutating func utteranceFinished(utteranceIdentifier: Int) -> (
        drawingsToStart: [String], finishedGroups: [String]
    ) {
        let drawings = fireAnchors { $0.utteranceIdentifier == utteranceIdentifier }
        var finishedGroups: [String] = []
        if let group = groupByUtterance.removeValue(forKey: utteranceIdentifier) {
            let remaining = (unfinishedUtteranceCountByGroup[group] ?? 1) - 1
            if remaining <= 0 {
                unfinishedUtteranceCountByGroup.removeValue(forKey: group)
                finishedGroups.append(group)
            } else {
                unfinishedUtteranceCountByGroup[group] = remaining
            }
        }
        return (drawings, finishedGroups)
    }

    public mutating func reset() {
        self = AnchorScheduler()
    }

    private mutating func fireAnchors(where shouldFire: (AnchorState) -> Bool) -> [String] {
        var drawings: [String] = []
        for (anchorName, anchorState) in anchors.sorted(by: { $0.value.offset < $1.value.offset })
        where !anchorState.hasFired && shouldFire(anchorState) {
            anchors[anchorName]?.hasFired = true
            drawings += pendingDrawingsByAnchor.removeValue(forKey: anchorName) ?? []
        }
        return drawings
    }
}
