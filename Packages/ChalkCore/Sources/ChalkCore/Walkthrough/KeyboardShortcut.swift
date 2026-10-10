import Foundation

/// A shortcut as a plan writes it ("⌥S", "Option-S", "Shift+D", "⇧⌘W", "Cmd Shift W"), parsed
/// so a `shortcut` step completes when the user presses it (§4.2.6 step 4).
public struct KeyboardShortcut: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable, Comparable {
        case control, option, shift, command

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        var spokenName: String {
            switch self {
            case .control: return "Control"
            case .option: return "Option"
            case .shift: return "Shift"
            case .command: return "Command"
            }
        }
    }

    public var modifiers: Set<Modifier>
    /// Lowercased key: a character ("s"), or a named key ("return", "space", "tab", "escape",
    /// "delete", "left", "right", "up", "down", "f1"…).
    public var key: String

    static let modifierWords: [String: Modifier] = [
        "⌃": .control, "ctrl": .control, "control": .control, "⌥": .option, "opt": .option,
        "option": .option, "alt": .option, "⇧": .shift, "shift": .shift, "⌘": .command,
        "cmd": .command, "command": .command,
    ]
    static let namedKeys: [String: String] = [
        "↩": "return", "⏎": "return", "enter": "return", "return": "return", "space": "space",
        "spacebar": "space", "tab": "tab", "⇥": "tab", "esc": "escape", "escape": "escape",
        "⎋": "escape", "delete": "delete", "backspace": "delete", "⌫": "delete", "←": "left",
        "→": "right", "↑": "up", "↓": "down", "left": "left", "right": "right", "up": "up",
        "down": "down",
    ]

    public init(modifiers: Set<Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil for anything that isn't one key plus modifiers.
    public init?(parsing text: String) {
        var remaining = text.trimmingCharacters(in: .whitespaces)
        var modifiers: Set<Modifier> = []
        // Leading modifier symbols written together: "⇧⌘W".
        while let first = remaining.first, let modifier = Self.modifierWords[String(first)] {
            modifiers.insert(modifier)
            remaining.removeFirst()
        }
        let tokens =
            remaining
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
        var key: String?
        for token in tokens {
            let lowercased = token.lowercased()
            if let modifier = Self.modifierWords[lowercased] {
                modifiers.insert(modifier)
            } else if let named = Self.namedKeys[lowercased] {
                guard key == nil else { return nil }
                key = named
            } else if lowercased.count == 1
                || (lowercased.hasPrefix("f") && Int(lowercased.dropFirst()) != nil)
            {
                guard key == nil else { return nil }
                key = lowercased
            } else {
                return nil
            }
        }
        // "-" itself as the key ("⌘-") is lost to the split above; zoom-out shortcuts are rare.
        guard let key else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    /// Does a key press match? `characters` is the key without modifiers applied
    /// (`charactersIgnoringModifiers`, lowercased by the caller), or a named key.
    public func matches(key pressedKey: String, modifiers pressedModifiers: Set<Modifier>) -> Bool {
        pressedKey.lowercased() == key && pressedModifiers == modifiers
    }

    /// "⇧⌘W", for the recap card.
    public var symbols: String {
        modifiers.sorted().map(\.symbol).joined()
            + (key.count == 1 ? key.uppercased() : key.capitalized)
    }

    /// "Shift Command W", for speech.
    public var spoken: String {
        (modifiers.sorted().map(\.spokenName) + [key.count == 1 ? key.uppercased() : key])
            .joined(separator: " ")
    }
}
