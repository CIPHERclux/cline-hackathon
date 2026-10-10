import Foundation

/// What Chalk remembers about the user (§4.3 "User memory"): preferences and facts they told
/// it, the apps they ask about, and their skill per app. Local only, inspectable and editable in
/// the panel; a short summary goes with each question (§10.1: ≤ 400 tokens).
public struct UserMemory: Codable, Equatable, Sendable {
    public enum SkillLevel: String, Codable, CaseIterable, Sendable {
        case beginner, intermediate, expert
    }

    public struct AppRecord: Codable, Equatable, Sendable {
        public var questionCount: Int
        public var walkthroughsCompleted: Int
        /// Set by the user in the panel, or by the model from what the user said.
        public var skill: SkillLevel?
        public var lastUsed: Date

        public init(
            questionCount: Int = 0, walkthroughsCompleted: Int = 0, skill: SkillLevel? = nil,
            lastUsed: Date
        ) {
            self.questionCount = questionCount
            self.walkthroughsCompleted = walkthroughsCompleted
            self.skill = skill
            self.lastUsed = lastUsed
        }
    }

    public static let maximumFactCount = 30
    public static let maximumFactLength = 160
    /// About 400 tokens.
    public static let maximumPromptCharacters = 1600
    /// Apps listed in the prompt, most recent first.
    static let promptAppCount = 6

    public var facts: [String]
    public var apps: [String: AppRecord]

    public init(facts: [String] = [], apps: [String: AppRecord] = [:]) {
        self.facts = facts
        self.apps = apps
    }

    public var isEmpty: Bool { facts.isEmpty && apps.isEmpty }

    /// Adds a fact unless it's already there (case- and punctuation-insensitive). The oldest
    /// fact goes when the list is full. Returns false for a duplicate or empty fact.
    @discardableResult
    public mutating func remember(_ fact: String) -> Bool {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let clipped =
            trimmed.count > Self.maximumFactLength
            ? String(trimmed.prefix(Self.maximumFactLength - 1)) + "…" : trimmed
        let normalized = FuzzyTextMatch.normalized(clipped)
        guard !facts.contains(where: { FuzzyTextMatch.normalized($0) == normalized }) else {
            return false
        }
        facts.append(clipped)
        if facts.count > Self.maximumFactCount {
            facts.removeFirst(facts.count - Self.maximumFactCount)
        }
        return true
    }

    public mutating func forget(factAt index: Int) {
        guard facts.indices.contains(index) else { return }
        facts.remove(at: index)
    }

    public mutating func recordQuestion(inApp appName: String, at date: Date) {
        var record = apps[appName] ?? AppRecord(lastUsed: date)
        record.questionCount += 1
        record.lastUsed = date
        apps[appName] = record
    }

    public mutating func recordWalkthroughCompleted(inApp appName: String, at date: Date) {
        var record = apps[appName] ?? AppRecord(lastUsed: date)
        record.walkthroughsCompleted += 1
        record.lastUsed = date
        apps[appName] = record
    }

    public mutating func setSkill(_ skill: SkillLevel?, forApp appName: String, at date: Date) {
        var record = apps[appName] ?? AppRecord(lastUsed: date)
        record.skill = skill
        apps[appName] = record
    }

    /// The model's `remember` line may name an app and a skill ("beginner in DaVinci Resolve").
    public mutating func apply(_ action: RememberAction, at date: Date) {
        if let appName = action.app?.trimmingCharacters(in: .whitespaces), !appName.isEmpty,
            let skill = action.skill.flatMap({ SkillLevel(rawValue: $0.lowercased()) })
        {
            setSkill(skill, forApp: appName, at: date)
        }
        remember(action.fact)
    }

    /// The `<memory>` block sent with a question; nil when there is nothing to say.
    public func promptBlock() -> String? {
        guard !isEmpty else { return nil }
        var lines: [String] = []
        if !facts.isEmpty {
            lines.append("About the user:")
            lines += facts.reversed().map { "- \($0)" }
        }
        let recentApps = apps.sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(Self.promptAppCount)
        if !recentApps.isEmpty {
            lines.append("Apps they use with Chalk:")
            for (name, record) in recentApps {
                var details: [String] = []
                if let skill = record.skill { details.append(skill.rawValue) }
                if record.walkthroughsCompleted > 0 {
                    details.append("\(record.walkthroughsCompleted) walkthroughs done")
                }
                lines.append(
                    "- \(name)\(details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")")
            }
        }
        var body = ""
        for line in lines {
            guard body.count + line.count + 1 <= Self.maximumPromptCharacters else { break }
            body += line + "\n"
        }
        return """
            <memory>
            \(body)Use this to pitch the answer (skip basics they know). Don't mention it unless asked.
            </memory>
            """
    }
}

/// Opt-in answering modes (§4.3 study mode, kids mode). Each adds a context line; the rules
/// (`00-teacher.md`, `30-safety.md`) say what they change.
public struct AssistantModes: Equatable, Sendable {
    public var isStudyModeOn: Bool
    public var isKidsModeOn: Bool

    public init(isStudyModeOn: Bool, isKidsModeOn: Bool) {
        self.isStudyModeOn = isStudyModeOn
        self.isKidsModeOn = isKidsModeOn
    }

    /// Kids mode speaks a little slower.
    public static let kidsSpeechRate = 0.74

    public var contextBlock: String? {
        var lines: [String] = []
        if isStudyModeOn {
            lines.append(
                "Study mode is on: for a problem or exercise, give a hint or a guiding question first and the full answer only when they ask again or say \"just tell me\". Never write out complete answers to homework, tests or graded work; help them get there."
            )
        }
        if isKidsModeOn {
            lines.append(
                "Kids mode is on: the user is a child. Use simple words and very short sentences, be warm and encouraging, keep everything age-appropriate, and gently decline anything that isn't (violence, adult topics, personal details, buying things)."
            )
        }
        guard !lines.isEmpty else { return nil }
        return "<modes>\n" + lines.joined(separator: "\n") + "\n</modes>"
    }
}
