import CoreGraphics

/// The outcome of re-reading the screen around a drawn mark (§6.2 f).
public enum VerificationVerdict: Equatable, Sendable {
    /// The expected text is inside the mark.
    case confirmed
    /// The text is on screen but somewhere else (scrolled, moved): redraw here (native pixels).
    case relocated(CGRect)
    /// The text isn't in the re-read crop at all.
    case notFound
    /// Nothing to check against (an icon, a region, a raw point).
    case notVerifiable
}

/// §6.2 (f): after drawing, a fresh crop around the target is re-OCR'd and must still show the
/// label the mark is about. Pure, so the decision is unit-tested; the app does the capture.
public enum VerificationCheck {
    /// Only words can be re-read reliably: OCR of maths and symbols ("V{ € R.(Eq.1)") comes out
    /// different every time, so checking it removed correct marks (owner's hand test). Text is
    /// verifiable when it has 3+ letters and is mostly letters and spaces.
    public static func isVerifiable(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let lettersAndSpaces = text.filter { $0.isLetter || $0 == " " }.count
        return letters >= 3 && Double(lettersAndSpaces) >= Double(text.count) * 0.8
    }

    public static func verify(expectedText: String?, markRect: CGRect, ocrLines: [Mark])
        -> VerificationVerdict
    {
        guard let expectedText, !FuzzyTextMatch.normalized(expectedText).isEmpty else {
            return .notVerifiable
        }
        let matches = ocrLines.filter {
            $0.kind == .text
                && FuzzyTextMatch.rank(candidate: $0.text ?? "", wanted: expectedText) != nil
        }
        guard !matches.isEmpty else { return .notFound }
        if matches.contains(where: { markRect.contains($0.center) }) { return .confirmed }
        let markCenter = CGPoint(x: markRect.midX, y: markRect.midY)
        let nearest = matches.min {
            hypot($0.center.x - markCenter.x, $0.center.y - markCenter.y)
                < hypot($1.center.x - markCenter.x, $1.center.y - markCenter.y)
        }
        return nearest.map { .relocated($0.box) } ?? .notFound
    }
}

/// §7.4 rule 5: verification or zoom failing twice in a turn escalates the zoom pass to the deep
/// slot, and §5.10 asks the learner to circle the thing instead of guessing again.
public struct GroundingEscalation: Sendable {
    public static let failuresBeforeEscalation = 2
    public private(set) var failureCount = 0

    public init() {}

    public mutating func recordFailure() { failureCount += 1 }
    public mutating func reset() { failureCount = 0 }

    public var zoomSlot: ModelSlot {
        failureCount >= Self.failuresBeforeEscalation ? .deep : .grounding
    }
    public var shouldAskLearnerToCircle: Bool {
        failureCount >= Self.failuresBeforeEscalation
    }
}
