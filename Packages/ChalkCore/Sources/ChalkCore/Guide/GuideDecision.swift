import Foundation

/// A question card's options, matched against what the user says (D82, D86). Exact names and
/// numbers match locally; anything else goes to the checker (GuideCoordinator.answer).
public struct AdaptiveDecision: Equatable, Sendable {
    public let question: String
    public let options: [String]

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }

    public func answer(matching transcript: String) -> String? {
        let normalized = FuzzyTextMatch.normalized(transcript)
        let ordinals = ["first", "second", "third", "fourth"]
        for (index, option) in options.prefix(4).enumerated() {
            if normalized == FuzzyTextMatch.normalized(option)
                || normalized == String(index + 1)
                || normalized == "option \(index + 1)"
                || normalized == ordinals[index]
            {
                return option
            }
        }
        return nil
    }
}
