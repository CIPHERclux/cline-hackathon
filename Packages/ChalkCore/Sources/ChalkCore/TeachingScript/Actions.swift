/// One validated Teaching Script v1 action (§6.4 action table). The model streams these as
/// NDJSON lines; the renderer and TTS consume them in order.
public enum ScriptAction: Equatable, Sendable {
    case meta(MetaAction)
    case speak(SpeakAction)
    case point(PointAction)
    case draw(DrawAction)
    case figure(FigureAction)
    case highlight(HighlightAction)
    case reveal(RevealAction)
    case clear(ClearAction)
    case waitForUser(WaitForUserAction)
    case waitForAction(WaitForActionAction)
    case check(CheckAction)
    /// Guided walkthroughs (§4.2.6, D70): the step being guided, the path's short outline, and
    /// a check turn's verdict. The walkthrough controller handles them, not the renderer.
    case step(WalkthroughStep)
    case outline([String])
    /// A check turn's answer: is step `step` done (D73). `step_done`/`not_done` lines map here.
    case verdict(WalkthroughVerdict)
    case goalDone
    /// A fact for user memory (§4.3).
    case remember(RememberAction)
    case end
}

public struct MetaAction: Equatable, Sendable {
    public var version: Int
    public var mode: String?
    public var language: String?
}

public struct SpeakAction: Equatable, Sendable {
    /// May contain `{anchorId}` markers that drawing actions reference with `at` (§4.2.4).
    public var text: String
    public var group: String?
    public var rate: Double?
    public var pauseAfterMilliseconds: Int?

    public init(
        text: String, group: String? = nil, rate: Double? = nil, pauseAfterMilliseconds: Int? = nil
    ) {
        self.text = text
        self.group = group
        self.rate = rate
        self.pauseAfterMilliseconds = pauseAfterMilliseconds
    }
}

public struct PointAction: Equatable, Sendable {
    public var target: TargetDescriptor
    public var anchor: String?
    public var label: String?
    public var identifier: String?
}

public struct DrawAction: Equatable, Sendable {
    public var shape: AnnotationShape
    /// Either `target`, or `from` + `to` for arrows.
    public var target: TargetDescriptor?
    public var from: TargetDescriptor?
    public var to: TargetDescriptor?
    public var anchor: String?
    public var role: String?
    public var label: String?
    public var life: String?
    public var identifier: String?
    public var group: String?

    public init(
        shape: AnnotationShape, target: TargetDescriptor?, from: TargetDescriptor?,
        to: TargetDescriptor?, anchor: String?, role: String?, label: String?, life: String?,
        identifier: String?, group: String?
    ) {
        self.shape = shape
        self.target = target
        self.from = from
        self.to = to
        self.anchor = anchor
        self.role = role
        self.label = label
        self.life = life
        self.identifier = identifier
        self.group = group
    }
}

public struct FigureAction: Equatable, Sendable {
    public var kind: FigureKind
    /// Declarative layout spec (§4.2.3); interpreted by the figure engine, not here.
    public var spec: JSONValue
    public var surface: String?
    public var anchor: String?
    public var identifier: String?
}

public struct HighlightAction: Equatable, Sendable {
    public var target: TargetDescriptor
    public var anchor: String?
    public var life: String?
}

public struct RevealAction: Equatable, Sendable {
    public var identifier: String
    public var part: JSONValue
    public var anchor: String?
}

public struct ClearAction: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case all
        case identifiers([String])
    }
    public var scope: Scope
    public var fadeMilliseconds: Int?
}

public struct WaitForUserAction: Equatable, Sendable {
    public var promptIdentifier: String
    public var timeoutSeconds: Double?
}

public struct WaitForActionAction: Equatable, Sendable {
    public var stepIdentifier: String
    public var target: TargetDescriptor
    public var expect: JSONValue
    public var timeoutSeconds: Double?
    public var hintLadder: JSONValue?
}

public struct CheckAction: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case free, choice
    }
    public var question: String
    public var kind: Kind
    public var choices: [String]?
    /// Kept local and never spoken (§6.4).
    public var answerKey: String?
}

/// Annotation primitives in the demo: the "Demo" column of §4.2.1 (D01). Anything else the
/// model names is dropped and logged, never rendered.
public enum AnnotationShape: String, Equatable, Sendable, CaseIterable {
    case ring
    case ellipse
    case rect
    case underline
    case highlight
    case arrow
    case curvedArrow = "curved_arrow"
    case label
    case stepBadge = "step_badge"

    /// §4.2.1 primitives that exist but are MVP/v1, so out of the demo (D01).
    public static let outOfDemoShapes: Set<String> = [
        "bracket", "connector", "freehand", "spotlight", "magnify", "ghost_cursor_demo", "strike",
        "cross",
    ]
}

/// Figures in the demo (§4.2.3): `numberline` (Demo) and `math_steps` (§4.7, D02).
public enum FigureKind: String, Equatable, Sendable, CaseIterable {
    case numberline
    case mathSteps = "math_steps"
    /// Shapes on the board (owner request, D59; §4.2.3 lists `geometry` for MVP).
    case geometry
}
