import CoreGraphics
import Foundation

/// A small grayscale copy of a screenshot for noticing that the screen changed while a step
/// waits (§6.7 tile diff). 64×40 tiles is enough to see a panel open.
public struct ScreenThumbnail: Equatable, Sendable {
    public static let columns = 64
    public static let rows = 40
    /// Row-major luminance, 0…255, row 0 at the top.
    public let luminance: [UInt8]

    public init(luminance: [UInt8]) {
        precondition(luminance.count == Self.columns * Self.rows)
        self.luminance = luminance
    }

    /// Nil only if CoreGraphics can't make a context.
    public init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: Self.columns, height: Self.rows,
                    bitsPerComponent: 8, bytesPerRow: Self.columns,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drewImage else { return nil }
        // CGContext rows run bottom-up; flip so row 0 is the top of the screen.
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        for row in 0..<Self.rows {
            let source = (Self.rows - 1 - row) * Self.columns
            flipped.replaceSubrange(
                row * Self.columns..<(row + 1) * Self.columns,
                with: pixels[source..<source + Self.columns])
        }
        self.init(luminance: flipped)
    }
}

public struct ScreenChange: Equatable, Sendable {
    /// Share of tiles that changed, 0…1.
    public var changedFraction: Double

    public init(changedFraction: Double) {
        self.changedFraction = changedFraction
    }

    /// A tile changed if its luminance moved by more than this (cursor blinks stay below it).
    static let tileThreshold = 18

    public static func between(_ before: ScreenThumbnail, _ after: ScreenThumbnail) -> ScreenChange
    {
        var changedCount = 0
        for index in before.luminance.indices
        where abs(Int(before.luminance[index]) - Int(after.luminance[index])) > tileThreshold {
            changedCount += 1
        }
        return ScreenChange(
            changedFraction: Double(changedCount) / Double(before.luminance.count))
    }
}

/// Why Chalk looks at the screen again during a walkthrough (D70). Each one becomes a check
/// turn: the model compares the screen with the step's "done when" and either moves on, stays
/// silent, or helps.
public enum WalkthroughTrigger: Equatable, Sendable {
    case click(onStepTarget: Bool)
    case drag(fromStepTarget: Bool)
    /// Typing paused.
    case typing
    case returnKey
    case shortcut(String)
    case screenChanged
    case appSwitched(to: String?)
    case userSaidDone
    case skipped(WalkthroughStep?)
    case wentBack(WalkthroughStep?)
    case startOver
    case stuck(seconds: Int)

    /// What the user asked for beats what they did, which beats what the screen did: a pending
    /// trigger is only replaced by a more important one.
    public var priority: Int {
        switch self {
        case .userSaidDone, .skipped, .wentBack, .startOver: return 0
        case .click, .drag, .typing, .returnKey, .shortcut, .appSwitched: return 1
        case .screenChanged, .stuck: return 2
        }
    }
}

/// When to look (D70). Pure, so the timings are tested.
public enum WalkthroughCheckPolicy {
    /// While a step waits, the screen is compared every this many seconds.
    public static let pollIntervalSeconds = 2.0
    /// A smaller change is a cursor, a tooltip or a clock.
    public static let pollChangeFraction = 0.03
    /// Screen-only looks are spaced out (a playing video changes every poll)…
    public static let minimumSecondsBetweenPollChecks = 6.0
    /// …and pause after this many in a row found nothing done, until the user acts again.
    public static let maximumIdlePollChecks = 2
    /// No progress for this long: look again and help (the hint ladder, §4.2.6 step 7).
    public static let stuckAfterSeconds: [Double] = [25, 60]

    /// Seconds to wait after an input before looking: the screen settles, typing pauses.
    public static func delaySeconds(for trigger: WalkthroughTrigger) -> Double {
        switch trigger {
        case .click, .drag: return 0.9
        case .typing: return 1.6
        case .returnKey: return 0.6
        case .shortcut: return 0.8
        case .appSwitched: return 1.2
        case .screenChanged, .userSaidDone, .skipped, .wentBack, .startOver, .stuck: return 0
        }
    }

    public static func shouldCheckAfterPoll(
        change: ScreenChange, appSwitched: Bool, secondsSinceLastCheck: Double,
        idlePollChecks: Int
    ) -> Bool {
        if appSwitched { return true }
        guard idlePollChecks < maximumIdlePollChecks else { return false }
        return change.changedFraction >= pollChangeFraction
            && secondsSinceLastCheck >= minimumSecondsBetweenPollChecks
    }

    /// A key press, as a trigger: ⌘/⌃/⌥ combinations are shortcuts, Return and Tab commit,
    /// anything else is typing. Escape is nil (it usually closes something in the app).
    public static func trigger(forKey key: String, modifiers: Set<KeyboardShortcut.Modifier>)
        -> WalkthroughTrigger?
    {
        if key == "escape" { return nil }
        if !modifiers.isDisjoint(with: [.command, .control, .option]) {
            return .shortcut(KeyboardShortcut(modifiers: modifiers, key: key).symbols)
        }
        if key == "return" || key == "tab" { return .returnKey }
        return .typing
    }
}
