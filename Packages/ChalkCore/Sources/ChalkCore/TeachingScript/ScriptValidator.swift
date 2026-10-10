import Foundation

/// What the parser hands the app: validated actions in order, plus diagnostics for anything it
/// dropped, downgraded or repaired. Diagnostics are for logs and the §11.2 malformed-rate metric;
/// they never reach the learner.
public enum ScriptEvent: Equatable, Sendable {
    case action(ScriptAction)
    case diagnostic(ScriptDiagnostic)
}

public enum ScriptDiagnostic: Equatable, Sendable {
    /// §6.4: unknown `type` → drop and log.
    case unknownType(String)
    /// A known action, primitive or figure that is MVP/v1 scope, e.g. `cite`, `draw:spotlight` (D01, D02).
    case outOfDemoScope(String)
    /// Required fields missing or of the wrong kind; the line is dropped.
    case invalidAction(type: String, reason: String)
    /// §6.4: a missing or unusable target turns `draw`/`point`/`highlight` into speech-only,
    /// reported as a low-confidence event.
    case downgradedToSpeechOnly(type: String, reason: String)
    /// The action uses a raw pixel target (§6.2 rule 5).
    case lowConfidenceTarget(type: String)
    /// A line that looked like JSON but could not be parsed, even after repair. Dropped, not
    /// spoken: reading braces aloud is worse than skipping a line.
    case malformedJSON(line: String)
    case repaired(ScriptRepair)
    /// §6.4: 2 KB arrived without a newline, so the buffered text was spoken as plain speech.
    case overlongLineSpokenAsText(byteCount: Int)
    case unsupportedVersion(Int)
    /// Prose outside JSON in a turn that doesn't speak it (a walkthrough check, D73).
    case plainTextDropped(String)
}

public enum ScriptRepair: Equatable, Sendable {
    case codeFence
    case trailingComma
    case arrayBracket
}

/// Maps one decoded JSON line to a typed action (§6.4 action table, demo allowlists D01/D02).
public enum ScriptValidator {
    public static let supportedVersion = 1

    public static func validate(_ json: JSONValue) -> [ScriptEvent] {
        guard let type = json["type"]?.stringValue else {
            return [.diagnostic(.invalidAction(type: "?", reason: "no type"))]
        }
        switch type {
        case "meta":
            let version = json["v"]?.integerValue ?? supportedVersion
            let meta = ScriptEvent.action(
                .meta(
                    MetaAction(
                        version: version, mode: json["mode"]?.stringValue,
                        language: json["lang"]?.stringValue)))
            return version == supportedVersion
                ? [meta] : [.diagnostic(.unsupportedVersion(version)), meta]

        case "speak":
            guard let text = json["text"]?.stringValue,
                !text.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return [.diagnostic(.invalidAction(type: type, reason: "speak needs text"))]
            }
            return [
                .action(
                    .speak(
                        SpeakAction(
                            text: text, group: json["group"]?.stringValue,
                            rate: json["rate"]?.numberValue,
                            pauseAfterMilliseconds: json["pause_after_ms"]?.integerValue)))
            ]

        case "point":
            guard let target = json["target"].flatMap(TargetDescriptor.init(json:)) else {
                return [
                    .diagnostic(
                        .downgradedToSpeechOnly(type: type, reason: "missing or unusable target"))
                ]
            }
            let point = PointAction(
                target: target, anchor: json["at"]?.stringValue, label: json["label"]?.stringValue,
                identifier: json["id"]?.stringValue)
            return withConfidence(.action(.point(point)), type: type, targets: [target])

        case "draw":
            return validateDraw(json)

        case "highlight":
            guard let target = json["target"].flatMap(TargetDescriptor.init(json:)) else {
                return [
                    .diagnostic(
                        .downgradedToSpeechOnly(type: type, reason: "missing or unusable target"))
                ]
            }
            let highlight = HighlightAction(
                target: target, anchor: json["at"]?.stringValue, life: json["life"]?.stringValue)
            return withConfidence(.action(.highlight(highlight)), type: type, targets: [target])

        case "figure":
            guard let kindName = json["kind"]?.stringValue else {
                return [.diagnostic(.invalidAction(type: type, reason: "figure needs kind"))]
            }
            guard let kind = FigureKind(rawValue: kindName) else {
                return [.diagnostic(.outOfDemoScope("figure:\(kindName)"))]
            }
            guard let spec = json["spec"], spec.isObject else {
                return [
                    .diagnostic(.invalidAction(type: type, reason: "figure needs a spec object"))
                ]
            }
            return [
                .action(
                    .figure(
                        FigureAction(
                            kind: kind, spec: spec, surface: json["surface"]?.stringValue,
                            anchor: json["at"]?.stringValue,
                            identifier: json["id"]?.stringValue)))
            ]

        case "reveal":
            guard let identifier = json["id"]?.stringValue, let part = json["part"] else {
                return [.diagnostic(.invalidAction(type: type, reason: "reveal needs id and part"))]
            }
            return [
                .action(
                    .reveal(
                        RevealAction(
                            identifier: identifier, part: part, anchor: json["at"]?.stringValue)))
            ]

        case "clear":
            let fadeMilliseconds = json["fade_ms"]?.integerValue
            if json["ids"]?.stringValue == "all" || json["all"] == .bool(true) {
                return [
                    .action(.clear(ClearAction(scope: .all, fadeMilliseconds: fadeMilliseconds)))
                ]
            }
            guard let identifiers = json["ids"]?.arrayValue?.compactMap(\.stringValue),
                !identifiers.isEmpty
            else {
                return [
                    .diagnostic(.invalidAction(type: type, reason: "clear needs ids or \"all\""))
                ]
            }
            return [
                .action(
                    .clear(
                        ClearAction(
                            scope: .identifiers(identifiers), fadeMilliseconds: fadeMilliseconds)))
            ]

        case "wait_for_user":
            guard let promptIdentifier = json["prompt_id"]?.stringValue else {
                return [
                    .diagnostic(.invalidAction(type: type, reason: "wait_for_user needs prompt_id"))
                ]
            }
            return [
                .action(
                    .waitForUser(
                        WaitForUserAction(
                            promptIdentifier: promptIdentifier,
                            timeoutSeconds: json["timeout_s"]?.numberValue)))
            ]

        case "wait_for_action":
            guard let stepIdentifier = json["step_id"]?.stringValue,
                let target = json["target"].flatMap(TargetDescriptor.init(json:)),
                let expect = json["expect"]
            else {
                return [
                    .diagnostic(
                        .invalidAction(
                            type: type, reason: "wait_for_action needs step_id, target and expect"))
                ]
            }
            let wait = WaitForActionAction(
                stepIdentifier: stepIdentifier, target: target, expect: expect,
                timeoutSeconds: json["timeout_s"]?.numberValue,
                hintLadder: json["hint_ladder"])
            return withConfidence(.action(.waitForAction(wait)), type: type, targets: [target])

        case "check":
            guard let question = json["question"]?.stringValue, !question.isEmpty,
                let kind = CheckAction.Kind(rawValue: json["kind"]?.stringValue ?? "free")
            else {
                return [
                    .diagnostic(
                        .invalidAction(
                            type: type, reason: "check needs question and kind free|choice"))
                ]
            }
            let choices = json["choices"]?.arrayValue?.compactMap(\.stringValue)
            if kind == .choice && (choices?.count ?? 0) < 2 {
                return [
                    .diagnostic(
                        .invalidAction(type: type, reason: "choice check needs at least 2 choices"))
                ]
            }
            return [
                .action(
                    .check(
                        CheckAction(
                            question: question, kind: kind, choices: choices,
                            answerKey: json["answer_key"]?.stringValue)))
            ]

        case "step":
            guard let step = WalkthroughStep(json: json) else {
                return [.diagnostic(.invalidAction(type: type, reason: "step needs instruction"))]
            }
            return [.action(.step(step))]

        case "outline":
            let steps = json["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !steps.isEmpty else {
                return [.diagnostic(.invalidAction(type: type, reason: "outline needs steps"))]
            }
            return [.action(.outline(steps))]

        case "verdict":
            guard let done = json["done"]?.boolValue else {
                return [.diagnostic(.invalidAction(type: type, reason: "verdict needs done"))]
            }
            let verdict = WalkthroughVerdict(step: json["step"]?.integerValue, done: done)
            return [.action(.verdict(verdict))]

        case "step_done":
            return [.action(.verdict(WalkthroughVerdict(step: nil, done: true)))]

        case "not_done":
            return [.action(.verdict(WalkthroughVerdict(step: nil, done: false)))]

        case "goal_done":
            return [.action(.goalDone)]

        case "remember":
            guard let fact = json["fact"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                !fact.isEmpty
            else {
                return [.diagnostic(.invalidAction(type: type, reason: "remember needs fact"))]
            }
            return [
                .action(
                    .remember(
                        RememberAction(
                            fact: fact, app: json["app"]?.stringValue,
                            skill: json["skill"]?.stringValue)))
            ]

        case "end":
            return [.action(.end)]

        case "cite":
            // Documents are MVP scope (§4.7); citations have nothing to show in the demo.
            return [.diagnostic(.outOfDemoScope("cite"))]

        default:
            return [.diagnostic(.unknownType(type))]
        }
    }

    private static func validateDraw(_ json: JSONValue) -> [ScriptEvent] {
        guard let shapeName = json["shape"]?.stringValue else {
            return [.diagnostic(.invalidAction(type: "draw", reason: "draw needs shape"))]
        }
        guard let shape = AnnotationShape(rawValue: shapeName) else {
            return AnnotationShape.outOfDemoShapes.contains(shapeName)
                ? [.diagnostic(.outOfDemoScope("draw:\(shapeName)"))]
                : [.diagnostic(.unknownType("draw:\(shapeName)"))]
        }
        let target = json["target"].flatMap(TargetDescriptor.init(json:))
        let from = json["from"].flatMap(TargetDescriptor.init(json:))
        let to = json["to"].flatMap(TargetDescriptor.init(json:))
        // Arrows may connect two targets; everything else needs one target.
        let isConnecting = (shape == .arrow || shape == .curvedArrow) && from != nil && to != nil
        guard target != nil || isConnecting else {
            return [
                .diagnostic(
                    .downgradedToSpeechOnly(
                        type: "draw:\(shapeName)", reason: "missing or unusable target"))
            ]
        }
        let draw = DrawAction(
            shape: shape, target: target, from: from, to: to, anchor: json["at"]?.stringValue,
            role: json["role"]?.stringValue,
            label: json["label"]?.stringValue, life: json["life"]?.stringValue,
            identifier: json["id"]?.stringValue,
            group: json["group"]?.stringValue)
        return withConfidence(
            .action(.draw(draw)), type: "draw:\(shapeName)",
            targets: [target, from, to].compactMap { $0 })
    }

    private static func withConfidence(
        _ event: ScriptEvent, type: String, targets: [TargetDescriptor]
    ) -> [ScriptEvent] {
        targets.contains(where: \.isLowConfidence)
            ? [event, .diagnostic(.lowConfidenceTarget(type: type))] : [event]
    }
}
