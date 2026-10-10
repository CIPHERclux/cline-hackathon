import CoreGraphics

/// The system screenshot chords (§6.6, P-SCRNSHOT): ⇧⌘3 (screen), ⇧⌘4 (area or window) and
/// ⇧⌘5 (toolbar and recording), each also with ⌃ to copy to the clipboard. Seeing one in the
/// listen-only key tap, Chalk hides its overlays for 10 s. Pure and allocation-free, so the tap
/// callback stays O(1) (P-HOTKEY).
public enum ScreenshotChord {
    /// ANSI key codes of the 3, 4 and 5 keys (key positions, so other layouts match too).
    static let screenshotKeyCodes: Set<UInt16> = [20, 21, 23]

    /// How long overlays stay hidden after a chord.
    public static let hideSeconds: Double = 10

    public static func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard screenshotKeyCodes.contains(keyCode) else { return false }
        // ⌘ and ⇧ are required; ⌃ is the clipboard variant; ⌥ makes it a different chord.
        return flags.contains(.maskCommand) && flags.contains(.maskShift)
            && !flags.contains(.maskAlternate)
    }
}
