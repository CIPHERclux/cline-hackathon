import Foundation

/// Is this question a procedure to guide through (§4.2.6 "Trigger": rule keywords first)? Maths
/// is not: "walk me through this proof" stays a worked solution on the whiteboard (D62).
public enum WalkthroughIntent {
    static let guidePhrases = [
        "guide me", "walk me through", "walkthrough", "take me through", "show me how to",
        "teach me how to", "teach me to", "help me set up", "help me setup", "step by step guide",
        "talk me through",
    ]
    /// "help me <verb>" asks for a procedure; "help me understand" does not.
    static let helpMeVerbs = [
        "make", "create", "add", "build", "export", "install", "configure", "connect", "colour",
        "color", "grade", "record", "change", "turn on", "turn off", "enable", "disable", "set",
        "insert", "format", "share", "organise", "organize",
    ]
    static let howPhrases = ["how do i", "how can i", "how to", "how would i"]
    static let stepPhrases = ["step by step", "steps", "one step at a time"]
    /// "I have to write a mail, what should I do?": a task the user wants done (owner's hand
    /// test, D69), recognised by a task phrase plus an action verb.
    static let taskPhrases = [
        "i have to", "i need to", "i want to", "i would like to", "i d like to", "i m trying to",
        "im trying to", "i am trying to", "what should i do", "what do i do", "where do i start",
        "how do i", "how can i", "how to", "how would i",
    ]
    static let taskVerbs: Set<String> = [
        "write", "send", "reply", "email", "mail", "make", "create", "add", "build", "export",
        "import", "install", "uninstall", "update", "configure", "connect", "set", "setup",
        "change", "turn", "enable", "disable", "insert", "format", "share", "organise",
        "organize", "save", "print", "delete", "remove", "rename", "move", "copy", "upload",
        "download", "attach", "book", "schedule", "sign", "log", "record", "edit", "crop",
        "resize", "colour", "color", "grade", "merge", "sort", "filter", "sync", "block", "mute",
        "unmute", "pair", "backup", "restore", "compose", "draft", "post", "publish", "convert",
        "compress", "zip", "rotate", "trim", "split", "join", "invite", "start", "open",
    ]
    /// Questions about something rather than asks to do something.
    static let explanationOpeners = ["what does", "what is", "what s", "why ", "explain"]

    public static func isWalkthroughRequest(_ question: String) -> Bool {
        let normalized = FuzzyTextMatch.normalized(question)
        let words = Set(normalized.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: QuestionContext.workedSolutionWords) { return false }
        // "guide me", "guide how to", "can you guide…": any use of the word asks for guidance.
        if words.contains("guide") { return true }
        if guidePhrases.contains(where: { normalized.contains($0) }) { return true }
        if helpMeVerbs.contains(where: { normalized.contains("help me \($0)") }),
            !normalized.contains("make sense")
        {
            return true
        }
        if howPhrases.contains(where: { normalized.contains($0) })
            && stepPhrases.contains(where: { normalized.contains($0) })
        {
            return true
        }
        if explanationOpeners.contains(where: { normalized.hasPrefix($0) }) { return false }
        return taskPhrases.contains(where: { normalized.contains($0) })
            && !words.isDisjoint(with: taskVerbs)
    }
}

extension WalkthroughIntent {
    /// Leading request words dropped from a how-to's title, longest first.
    static let titleLeadIns = [
        "can you please", "could you please", "can you", "could you", "please", "hey chalk",
        "chalk", "guide me through how to", "guide me on how to", "guide me how to",
        "guide me through", "guide me to", "guide me", "walk me through how to",
        "walk me through", "take me through how to", "take me through", "talk me through",
        "show me how to", "teach me how to", "teach me to", "help me to", "help me",
        "how do i", "how can i", "how to", "step by step",
    ]

    /// "Guide me how to colour grade this" → "Colour grade this", for the recap and how-to list.
    public static func taskTitle(from goal: String) -> String {
        var title = goal.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var changed = true
        while changed {
            changed = false
            for leadIn in titleLeadIns where title.lowercased().hasPrefix(leadIn + " ") {
                title = String(title.dropFirst(leadIn.count)).trimmingCharacters(
                    in: .whitespaces.union(.punctuationCharacters))
                changed = true
            }
        }
        for trailer in [" step by step", " please"] where title.lowercased().hasSuffix(trailer) {
            title = String(title.dropLast(trailer.count))
        }
        guard !title.isEmpty else { return goal }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

/// Voice commands during a walkthrough (§4.2.6 steps 4 and 8). Anything else is a question.
public enum WalkthroughCommand: Equatable, Sendable {
    case next, skip, back, startOver, stop, repeatStep, why
    /// "I'm lost", "that's not there": the screen doesn't match the plan; plan again from here.
    case replanHere

    /// Only short utterances are commands: "what does next do?" is a question.
    static let maximumCommandWordCount = 6
    static let phrases: [(WalkthroughCommand, [String])] = [
        (
            .replanHere,
            [
                "i'm lost", "im lost", "i am lost", "that's not there", "that s not there",
                "it's not there", "it s not there", "its not there", "it looks different",
                "looks different", "that's wrong", "that s wrong", "something's wrong",
                "something s wrong", "guide me from here", "continue from here", "continue here",
                "start again from here", "from here", "replan", "re plan", "not on my screen",
                "i don't see it", "i dont see it", "i don't see that", "i dont see that",
            ]
        ),
        (.startOver, ["start over", "start again", "from the beginning", "restart"]),
        (
            .stop,
            [
                "stop", "cancel", "quit", "end the walkthrough", "exit", "that's enough",
                "that s enough", "never mind", "nevermind",
            ]
        ),
        (.back, ["go back", "previous step", "back", "undo that step"]),
        (.skip, ["skip", "skip this", "skip it", "skip that"]),
        (
            .repeatStep,
            [
                "repeat", "say that again", "again", "where is it", "where", "i can't find it",
                "i cant find it",
            ]
        ),
        (.why, ["why", "why this step", "why do that", "why do i do this"]),
        (
            .next,
            [
                "next", "done", "i did it", "did it", "ok next", "okay next", "next step",
                "continue", "go on", "finished", "i'm done", "im done", "got it",
            ]
        ),
    ]

    public static func parse(_ transcript: String) -> WalkthroughCommand? {
        let normalized = FuzzyTextMatch.normalized(transcript)
        let words = normalized.split(separator: " ")
        guard !words.isEmpty, words.count <= maximumCommandWordCount else { return nil }
        for (command, commandPhrases) in phrases {
            for phrase in commandPhrases {
                let normalizedPhrase = FuzzyTextMatch.normalized(phrase)
                // Whole-utterance match, or the phrase as whole words with only fillers around.
                if normalized == normalizedPhrase { return command }
                let padded = " \(normalized) "
                if padded.contains(" \(normalizedPhrase) "),
                    words.count <= normalizedPhrase.split(separator: " ").count + 2,
                    !isQuestion(normalized)
                {
                    return command
                }
            }
        }
        return nil
    }

    private static func isQuestion(_ normalized: String) -> Bool {
        ["what", "how", "which", "does", "is", "can"].contains {
            normalized.hasPrefix("\($0) ")
        }
    }
}
