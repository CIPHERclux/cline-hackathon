import CoreGraphics
import Testing

@testable import ChalkCore

@Suite("Screenshot chords (§6.6, P-SCRNSHOT)")
struct ScreenshotChordTests {
    // ANSI key codes of the 3, 4 and 5 keys.
    static let keyThree: UInt16 = 20
    static let keyFour: UInt16 = 21
    static let keyFive: UInt16 = 23
    static let commandShift: CGEventFlags = [.maskCommand, .maskShift]

    @Test("⇧⌘3, ⇧⌘4 and ⇧⌘5 match, including the ⌃ copy-to-clipboard variants")
    func systemChordsMatch() {
        for keyCode in [Self.keyThree, Self.keyFour, Self.keyFive] {
            #expect(ScreenshotChord.matches(keyCode: keyCode, flags: Self.commandShift))
            #expect(
                ScreenshotChord.matches(
                    keyCode: keyCode, flags: Self.commandShift.union(.maskControl)))
        }
    }

    @Test("caps lock or a numeric-pad flag doesn't stop a match")
    func harmlessFlagsIgnored() {
        #expect(
            ScreenshotChord.matches(
                keyCode: Self.keyFour,
                flags: Self.commandShift.union([.maskAlphaShift, .maskNumericPad])))
    }

    @Test("no false positives: ⌘3, ⇧3, ⌥⇧⌘4, ⇧⌘6 and ⇧⌘A don't match")
    func otherChordsDontMatch() {
        #expect(!ScreenshotChord.matches(keyCode: Self.keyThree, flags: .maskCommand))
        #expect(!ScreenshotChord.matches(keyCode: Self.keyThree, flags: .maskShift))
        #expect(!ScreenshotChord.matches(keyCode: Self.keyFour, flags: []))
        #expect(
            !ScreenshotChord.matches(
                keyCode: Self.keyFour, flags: Self.commandShift.union(.maskAlternate)))
        // 6 (key code 22) and A (key code 0) with ⇧⌘.
        #expect(!ScreenshotChord.matches(keyCode: 22, flags: Self.commandShift))
        #expect(!ScreenshotChord.matches(keyCode: 0, flags: Self.commandShift))
    }
}
