import CoreGraphics
import Testing

@testable import ChalkCore

@Suite("System shortcut outcome evidence (D85)")
struct SystemShortcutOutcomeTests {
    @Test("Command Space Spotlight step is recognized without a delivered key event")
    func shortcutIntent() {
        #expect(
            SystemShortcutOutcome.opensSpotlight(
                WalkthroughStep(
                    kind: .shortcut, instruction: "Open Spotlight", shortcut: "Cmd Space")))
        #expect(
            SystemShortcutOutcome.opensSpotlight(
                WalkthroughStep(
                    kind: .shortcut, instruction: "Press Command Space",
                    doneWhen: "Spotlight is visible", shortcut: "⌘Space")))
        #expect(
            !SystemShortcutOutcome.opensSpotlight(
                WalkthroughStep(
                    kind: .shortcut, instruction: "Switch input source", shortcut: "⌘Space")))
        #expect(
            !SystemShortcutOutcome.opensSpotlight(
                WalkthroughStep(kind: .shortcut, instruction: "Open Spotlight", shortcut: "⌃Space"))
        )
    }

    @Test("only Spotlight's visible enabled focused search field proves outcome")
    func focusedSearch() {
        var snapshot = AccessibilitySnapshot(
            appName: "Spotlight", bundleIdentifier: "com.apple.Spotlight", focusedWindowTitle: nil,
            documentURL: nil,
            nodes: [
                AccessibilityNode(
                    role: "AXSearchField", frame: CGRect(x: 200, y: 100, width: 600, height: 50),
                    isFocused: true)
            ])
        #expect(SystemShortcutOutcome.spotlightSearchIsFocused(snapshot))
        snapshot.nodes[0].isFocused = false
        #expect(!SystemShortcutOutcome.spotlightSearchIsFocused(snapshot))
        snapshot.nodes[0].isFocused = true
        snapshot.nodes[0].frame = .zero
        #expect(!SystemShortcutOutcome.spotlightSearchIsFocused(snapshot))
        snapshot.nodes[0].frame = CGRect(x: 0, y: 0, width: 600, height: 50)
        snapshot.bundleIdentifier = "com.apple.Safari"
        #expect(!SystemShortcutOutcome.spotlightSearchIsFocused(snapshot))
        #expect(!SystemShortcutOutcome.spotlightSearchIsFocused(nil))
    }
}
