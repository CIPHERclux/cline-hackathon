import Foundation

/// System shortcuts may never reach NSEvent's monitor; verify their specific UI outcome (D85).
public enum SystemShortcutOutcome {
    public static func opensSpotlight(_ step: WalkthroughStep) -> Bool {
        guard step.kind == .shortcut,
            let shortcut = step.shortcut.flatMap(KeyboardShortcut.init(parsing:)),
            shortcut.key == "space", shortcut.modifiers == [.command]
        else { return false }
        let context = [step.instruction, step.doneWhen, step.doneJSON].compactMap { $0 }.joined(
            separator: " ")
        return context.localizedCaseInsensitiveContains("spotlight")
    }

    public static func spotlightSearchIsFocused(_ snapshot: AccessibilitySnapshot?) -> Bool {
        guard let snapshot, snapshot.bundleIdentifier == "com.apple.Spotlight" else { return false }
        return snapshot.nodes.contains { node in
            ["AXTextField", "AXSearchField", "AXComboBox"].contains(node.role)
                && node.isFocused && node.isEnabled && node.frame.width > 20
                && node.frame.height > 10
        }
    }
}
