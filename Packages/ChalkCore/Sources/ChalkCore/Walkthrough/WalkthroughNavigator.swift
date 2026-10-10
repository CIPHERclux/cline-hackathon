import Foundation

/// Where the user is against the whole plan (D75), decided locally from the accessibility tree,
/// so leaving the plan is noticed in about a second and most of it is handled without a model.
public enum WalkthroughNavigator {
    /// How far ahead a jump may reach.
    public static let lookAheadSteps = 3

    /// A later step whose `done` was false when the current step was shown and is true now: the
    /// user did it (and what came before). Returns the furthest such step's index. A predicate
    /// that was already true then (a default setting) never causes a jump.
    public static func jumpTarget(
        currentIndex: Int, baseline: [Int: Bool], now: [Int: Bool]
    ) -> Int? {
        now.keys.filter { index in
            index > currentIndex && now[index] == true && baseline[index] == false
        }.max()
    }

    /// Whether a finished step's predicate turning false means the user undid it. Focus moves
    /// on naturally ("focused: To" stops being true when they move to Subject), so it doesn't.
    public static func canRegress(_ predicate: DonePredicate) -> Bool {
        // A disappeared popup/window or changed selection is normal navigation, not undo.
        // Only an explicit user undo signal may initiate recovery; no automatic regression.
        return false
    }

    /// Dialogs and sheets on screen, to notice one the plan didn't expect.
    public static func dialogs(in snapshot: AccessibilitySnapshot) -> [AccessibilityNode] {
        snapshot.nodes.filter {
            $0.role == "AXSheet"
                || ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains($0.subrole ?? "")
        }
    }

    /// The words of a dialog, for asking how to get past it: its title and the texts inside it.
    public static func dialogText(_ dialog: AccessibilityNode, in snapshot: AccessibilitySnapshot)
        -> String
    {
        let inside = snapshot.nodes.filter {
            dialog.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        let words = ([dialog.title] + inside.flatMap { [$0.title, $0.label, $0.value] })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(20).joined(separator: " · ")
    }
}
