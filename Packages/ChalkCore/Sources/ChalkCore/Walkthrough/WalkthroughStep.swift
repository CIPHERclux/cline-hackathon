import CoreGraphics
import Foundation

/// One step of a guided walkthrough's plan (D74). The model plans once, in meaning rather than
/// pixels: which control (role and name), what the user does, and how the app can tell it's
/// done. The app then runs the step locally: finds the control in the accessibility tree (else
/// OCR, else one quick model look), says the instruction, and watches for `done`.
public struct WalkthroughStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case click, drag, menu, shortcut, type, observe
    }

    public var kind: Kind
    /// The step's number in the plan, as the model numbered it.
    public var number: Int?
    /// One sentence for the ear (also the recap line).
    public var instruction: String
    /// The control to use, by role and name, as the app shows it.
    public var target: ElementQuery?
    /// The app the step happens in ("Google Chrome", "Dock"), when the plan says (D76).
    public var app: String?
    /// The model's 0–1000 point on the screen it planned from; only used on that screen.
    public var targetPointNorm1000: CGPoint?
    /// A short description for finding a control without a readable name ("pencil icon").
    public var label: String?
    /// The `done` predicate as JSON text (kept as text so saved how-tos stay readable).
    public var doneJSON: String?
    /// What the screen shows once it's done, in words: for the model check when the app can't
    /// read `done` itself.
    public var doneWhen: String?
    public var shortcut: String?
    /// One sentence, spoken only when asked.
    public var why: String?

    public init(
        kind: Kind, instruction: String, number: Int? = nil, target: ElementQuery? = nil,
        app: String? = nil, targetPointNorm1000: CGPoint? = nil, label: String? = nil,
        doneJSON: String? = nil, doneWhen: String? = nil, shortcut: String? = nil,
        why: String? = nil
    ) {
        self.kind = kind
        self.app = app
        self.number = number
        self.instruction = instruction
        self.target = target
        self.targetPointNorm1000 = targetPointNorm1000
        self.label = label
        self.doneJSON = doneJSON
        self.doneWhen = doneWhen
        self.shortcut = shortcut
        self.why = why
    }

    public var done: DonePredicate? {
        doneJSON.flatMap(JSONValue.parse).flatMap(DonePredicate.init(json:))
    }

    /// Whether the step has a control to circle. A keyboard step only has one when the plan
    /// named a control (its label alone, "Spotlight search", names something that isn't there
    /// yet and cost a 13 s re-plan, D76).
    public var hasTarget: Bool {
        switch kind {
        case .shortcut: return target != nil
        case .type, .observe: return target != nil || targetPointNorm1000 != nil
        case .click, .menu, .drag:
            return target != nil || targetPointNorm1000 != nil || label != nil
        }
    }

    /// Steps whose control must be on screen: if it can't be found, the plan no longer fits.
    public var needsVisibleControl: Bool {
        kind == .click || kind == .menu || kind == .drag
    }

    /// What to look for when the control isn't in the tree or readable on screen.
    public var targetDescription: String {
        label ?? target?.name ?? instruction
    }

    /// Parses a validated `step` line. Nil when it has no instruction.
    init?(json: JSONValue) {
        guard let instruction = json["instruction"]?.stringValue,
            !instruction.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        func nonEmpty(_ key: String) -> String? {
            guard let value = json[key]?.stringValue?.trimmingCharacters(in: .whitespaces),
                !value.isEmpty, value.lowercased() != "null"
            else { return nil }
            return value
        }
        var target: ElementQuery?
        var point: CGPoint?
        if let targetJSON = json["target"] {
            target = ElementQuery(json: targetJSON)
            if target == nil, let text = targetJSON["text"]?.stringValue, !text.isEmpty {
                target = ElementQuery(role: .any, name: text)
            }
            if let coordinates = targetJSON["px"]?.arrayValue, coordinates.count == 2,
                let x = coordinates[0].numberValue, let y = coordinates[1].numberValue
            {
                point = CGPoint(x: x, y: y)
            }
        }
        self.init(
            kind: json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) ?? .click,
            instruction: instruction, number: (json["step"] ?? json["n"])?.integerValue,
            target: target, app: nonEmpty("app"), targetPointNorm1000: point,
            label: nonEmpty("label"),
            doneJSON: json["done"].flatMap(\.compactJSONText), doneWhen: nonEmpty("done_when"),
            shortcut: nonEmpty("shortcut"), why: nonEmpty("why"))
    }
}

extension WalkthroughStep {
    /// The planned step with what a live look changed (D77): its instruction, control, point
    /// and done predicate; everything else stays as planned.
    public func adapted(by json: JSONValue) -> WalkthroughStep {
        var step = self
        if let instruction = json["instruction"]?.stringValue?.trimmingCharacters(in: .whitespaces),
            !instruction.isEmpty
        {
            step.instruction = instruction
        }
        if let targetJSON = json["target"], targetJSON.isObject {
            if let query = ElementQuery(json: targetJSON) {
                step.target = query
            }
            if let coordinates = targetJSON["px"]?.arrayValue, coordinates.count == 2,
                let x = coordinates[0].numberValue, let y = coordinates[1].numberValue
            {
                step.targetPointNorm1000 = CGPoint(x: x, y: y)
            } else if ElementQuery(json: targetJSON) != nil {
                // A new control without a point: the planned point belonged to the old one.
                step.targetPointNorm1000 = nil
            }
        }
        // Only a predicate the app can read replaces the planned one (a made-up kind would
        // leave the step with no way to tell it's done).
        if let doneValue = json["done"], DonePredicate(json: doneValue) != nil,
            let doneJSON = doneValue.compactJSONText
        {
            step.doneJSON = doneJSON
        }
        if let doneWhen = json["done_when"]?.stringValue, !doneWhen.isEmpty {
            step.doneWhen = doneWhen
        }
        return step
    }
}

extension JSONValue {
    /// Compact JSON text for this value (nil for one that can't be written).
    public var compactJSONText: String? {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: foundationObject, options: [.fragmentsAllowed, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `{"type":"remember","fact":"…"}`: something the user told Chalk about themselves (§4.3 user
/// memory). Script line rather than a tool, so it costs no extra model iteration.
public struct RememberAction: Equatable, Sendable {
    public var fact: String
    public var app: String?
    public var skill: String?
}

/// `{"type":"verdict","step":4,"done":true}`: a check's answer (kept for replies that send it).
public struct WalkthroughVerdict: Equatable, Sendable {
    public var step: Int?
    public var done: Bool

    public init(step: Int?, done: Bool) {
        self.step = step
        self.done = done
    }
}
