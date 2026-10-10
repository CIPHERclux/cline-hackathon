import CoreGraphics
import Foundation

// The guide's multi-agent walkthrough (§4.2.6, D86): one coordinator, parallel bounded helpers
// (planner, scout, checker, fixer), one shared task ledger. Everything here is pure so the app
// and the headless use-case simulator (Eval/guide-sim) drive the same logic.

/// A word or label read from the screen (OCR), for apps without an accessibility tree.
public struct GuideVisibleText: Equatable, Sendable {
    public var text: String
    /// Global top-left points, the accessibility tree's space.
    public var frame: CGRect

    public init(text: String, frame: CGRect) {
        self.text = text
        self.frame = frame
    }
}

/// One look at the user's screen. `tree` observations carry only the accessibility snapshot
/// (cheap, no screenshot); `full` ones add the screenshot and, for unreadable apps, OCR text.
public struct GuideObservation: Sendable {
    public var identifier = UUID()
    public var appName: String?
    public var bundleIdentifier: String?
    public var snapshot: AccessibilitySnapshot?
    public var visibleTexts: [GuideVisibleText]
    public var imageJPEG: Data?
    /// The screenshot's area in global top-left points (for 0–1000 coordinates).
    public var screenFrame: CGRect
    /// App names in the Dock, so the planner knows what one click can open.
    public var dockItems: [String]
    public var capturedAt: Date
    /// Chalk itself is in front (its own panels): never a reason to pause.
    public var isChalkInFront: Bool

    public init(
        appName: String?, bundleIdentifier: String?, snapshot: AccessibilitySnapshot?,
        visibleTexts: [GuideVisibleText] = [], imageJPEG: Data? = nil,
        screenFrame: CGRect = .zero, dockItems: [String] = [], capturedAt: Date = Date(),
        isChalkInFront: Bool = false
    ) {
        self.dockItems = dockItems
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.snapshot = snapshot
        self.visibleTexts = visibleTexts
        self.imageJPEG = imageJPEG
        self.screenFrame = screenFrame
        self.capturedAt = capturedAt
        self.isChalkInFront = isChalkInFront
    }

    public var hasScreenshot: Bool { imageJPEG != nil }

    /// OCR words, for predicates on apps without a tree.
    public var visibleWords: [String]? {
        visibleTexts.isEmpty ? nil : visibleTexts.map(\.text)
    }

    public func evaluate(_ predicate: DonePredicate?) -> Bool? {
        predicate?.evaluate(
            snapshot: snapshot, frontmostAppName: appName, visibleTexts: visibleWords)
    }
}

public enum GuideObservationDepth: Sendable {
    case tree, full
}

/// What the user just did, from the listen-only input monitor and accessibility notifications.
public enum GuideUserEvent: Equatable, Sendable {
    case click(onTarget: Bool)
    case typed
    case returnKey
    case tabKey
    case escapeKey
    case shortcut(key: String, modifiers: Set<KeyboardShortcut.Modifier>)
    /// An accessibility notification or the 1 s poll: something may have changed.
    case screenMayHaveChanged
    case appSwitched
}

/// The helper roles (D86). Each is one bounded, stateless `complete` call that reads the shared
/// ledger; Chalk coordinates them, never agents calling agents.
public enum GuideRole: String, Sendable, CaseIterable {
    /// The next single action from the current screen (Sonnet).
    case planner
    /// Predicts the step after the current one while the user acts (Sonnet, background).
    case scout
    /// Quick yes/no looks: did the step work, is a predicted step right, is the goal reached,
    /// which option did the user mean (Haiku).
    case checker
    /// Only when stuck: a fresh, stronger look at what went wrong (Opus).
    case fixer

    public var slot: ModelSlot {
        switch self {
        case .planner, .scout: return .teaching
        case .checker: return .fast
        case .fixer: return .deep
        }
    }
}

public struct GuideModelRequest: Sendable {
    public var role: GuideRole
    public var slot: ModelSlot
    public var system: String
    public var prompt: String
    public var imageJPEG: Data?
    public var maxTokens: Int
    public var timeoutSeconds: Double

    public init(
        role: GuideRole, slot: ModelSlot? = nil, system: String, prompt: String,
        imageJPEG: Data?, maxTokens: Int, timeoutSeconds: Double
    ) {
        self.role = role
        self.slot = slot ?? role.slot
        self.system = system
        self.prompt = prompt
        self.imageJPEG = imageJPEG
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Where the guide's world comes from: the real Mac in the app, a scripted screen in the
/// simulator.
@MainActor
public protocol GuideEnvironment: AnyObject {
    /// `settle`: wait (bounded) until the screen stops changing, so a loading page or an
    /// animating menu is read once it is done.
    func observe(_ depth: GuideObservationDepth, settle: Bool) async -> GuideObservation
    /// Streams text deltas. The stream ends at done, error or the request's deadline; a
    /// cancelled consumer aborts the call.
    func streamModel(_ request: GuideModelRequest) -> AsyncStream<String>
    /// Apps the user has open (the planner takes the shortest path from them).
    func openAppNames() -> [String]
}

public struct GuidePresentation: Sendable {
    public var step: WalkthroughStep
    public var number: Int
    /// Steps expected in total (a planner estimate), for "Step 3 of ~7".
    public var estimatedTotal: Int?
    /// Chalk's own lead-in, always first ("Okay, here's the next step."); the model's
    /// instruction never starts with one, so they don't overlap.
    public var leadIn: String?
    /// Spoken before the instruction ("Back to it.").
    public var preface: String?
    /// Spoken after it, for actions with consequences ("This sends the email.").
    public var headsUp: String?
    public var isRepeat: Bool
    public var speaks: Bool
    /// The step's 0–1000 point was planned on the observation it will be shown on.
    public var pointIsFresh: Bool
    public var observation: GuideObservation

    public var spokenText: String {
        var parts: [String] = []
        if let leadIn { parts.append(leadIn) }
        if let preface { parts.append(preface) }
        parts.append(WalkthroughPrompts.spokenInstruction(for: step, isRepeat: isRepeat))
        if let headsUp { parts.append(headsUp) }
        return parts.joined(separator: " ")
    }
}

public enum GuidePresentResult: Equatable, Sendable {
    /// Circled (frame in global top-left points, with how it was found) or said without a
    /// circle (a shortcut).
    case shown(target: CGRect?, source: String)
    /// The step needs a control that isn't on screen.
    case missing
}

/// What the guide asks the app to do. The app speaks, draws and shows panels.
@MainActor
public protocol GuideDelegate: AnyObject {
    func guideStatus(_ text: String?)
    func guidePresent(_ presentation: GuidePresentation) async -> GuidePresentResult
    /// The current step's circle goes (the user acted, or the step ended).
    func guideClearStep()
    func guideSpeak(_ text: String)
    /// A short line while Chalk thinks ("Working out the next step."). Queued, never cutting
    /// anything off; the next step's speech waits for it.
    func guideFiller(_ text: String)
    /// A pointed reminder ("It's right here.") on the current step's control.
    func guideNudge()
    func guideAsk(question: String, options: [String])
    func guideHideQuestion()
    func guidePaused(_ isPaused: Bool, appName: String?)
    func guideFinished(steps: [WalkthroughStep])
    func guideEnded()
    func guideTrace(_ event: GuideTraceEvent)
}

/// Content-light trace for logs and the simulator's report.
public enum GuideTraceEvent: Sendable, Equatable {
    case modelCall(role: GuideRole, milliseconds: Int, succeeded: Bool)
    case presented(number: Int, source: String, millisecondsSinceUserAction: Int?)
    case stepDone(number: Int, how: String)
    case candidate(verdict: String)
    case asked(question: String, options: [String])
    case recovery(reason: String)
    case note(String)
    /// A helper answered but nothing usable came out (its start, for debugging only).
    case unusableReply(role: GuideRole, excerpt: String)
}
