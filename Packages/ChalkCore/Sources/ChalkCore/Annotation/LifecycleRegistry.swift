import Foundation

/// How long a mark lives (§4.2.2 rule 1).
public enum MarkLifecycle: Equatable, Sendable {
    /// Fades after 2.0 s (rings, quick highlights).
    case transient
    /// Lives while its sentence group is spoken, then fades; nil group: until the turn ends.
    case speechBound(group: String?)
    /// Lives until its walkthrough step completes.
    case stepBound
    case pinned
    case board
}

/// What a mark counts against in the ink budget (§4.2.2 rule 2).
public enum InkKind: Equatable, Sendable {
    case emphasis, spotlight, stepBadge
}

/// The registry of live marks (§4.2.2). Pure and clock-free: callers pass `now`, and every
/// mutating call returns the ids that must fade, so the renderer stays a thin executor and the
/// rules are unit-tested (P-LEFTOVER, budget, fades).
public struct LifecycleRegistry: Sendable {
    /// §4.2.2 says 2.0 s; the owner found marks gone before they could look (D58).
    public static let transientLifetimeSeconds: TimeInterval = 4.0
    public static let maximumEmphasisMarks = 3
    public static let maximumSpotlights = 1

    public struct Entry: Equatable, Sendable {
        public var identifier: String
        public var lifecycle: MarkLifecycle
        public var ink: InkKind
        public var createdAt: TimeInterval
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Adds a mark; returns ids evicted to keep the budget (oldest first). Re-adding an id replaces it.
    public mutating func add(
        identifier: String, lifecycle: MarkLifecycle, ink: InkKind, now: TimeInterval
    ) -> [String] {
        var evicted = remove(identifiers: [identifier], reportRemoved: false)
        entries.append(
            Entry(identifier: identifier, lifecycle: lifecycle, ink: ink, createdAt: now))
        let budget: [(InkKind, Int)] = [
            (.emphasis, Self.maximumEmphasisMarks), (.spotlight, Self.maximumSpotlights),
        ]
        for (ink, maximum) in budget {
            // Pinned and board marks are off the live budget.
            let counted = entries.filter { $0.ink == ink && !$0.lifecycle.isPinnedOrBoard }
            for entry in counted.prefix(max(0, counted.count - maximum)) {
                evicted += remove(identifiers: [entry.identifier], reportRemoved: true)
            }
        }
        return evicted
    }

    /// Transient marks older than 2.0 s.
    public mutating func expireTransients(now: TimeInterval) -> [String] {
        let expired = entries.filter {
            $0.lifecycle == .transient && now - $0.createdAt >= Self.transientLifetimeSeconds
        }
        return remove(identifiers: expired.map(\.identifier), reportRemoved: true)
    }

    /// When the next transient mark expires, for a one-shot timer (nothing periodic, P-IDLECPU).
    public var nextTransientExpiry: TimeInterval? {
        entries.filter { $0.lifecycle == .transient }.map {
            $0.createdAt + Self.transientLifetimeSeconds
        }.min()
    }

    /// The sentence group finished speaking: its speech-bound marks fade.
    public mutating func groupFinished(_ group: String) -> [String] {
        let finished = entries.filter { $0.lifecycle == .speechBound(group: group) }
        return remove(identifiers: finished.map(\.identifier), reportRemoved: true)
    }

    /// The script's `clear` action.
    public mutating func clear(identifiers: [String]) -> [String] {
        remove(identifiers: identifiers, reportRemoved: true)
    }

    /// Cleanup triggers and terminal states (§4.2.2 rules 3 and 5): everything except pinned
    /// and board marks.
    public mutating func clearAllExceptPinnedAndBoard() -> [String] {
        remove(
            identifiers: entries.filter { !$0.lifecycle.isPinnedOrBoard }.map(\.identifier),
            reportRemoved: true)
    }

    /// The no-leftovers invariant (P-LEFTOVER).
    public var isEmptyExceptPinnedAndBoard: Bool {
        entries.allSatisfy { $0.lifecycle.isPinnedOrBoard }
    }

    public var liveIdentifiers: [String] { entries.map(\.identifier) }

    private mutating func remove(identifiers: [String], reportRemoved: Bool) -> [String] {
        let identifierSet = Set(identifiers)
        let removed = entries.filter { identifierSet.contains($0.identifier) }.map(\.identifier)
        entries.removeAll { identifierSet.contains($0.identifier) }
        return reportRemoved ? removed : []
    }
}

extension MarkLifecycle {
    var isPinnedOrBoard: Bool {
        switch self {
        case .pinned, .board: return true
        default: return false
        }
    }

    /// Defaults per primitive (§4.2.1 table) unless the script says `life`.
    public static func forDrawing(shape: AnnotationShape, life: String?, group: String?)
        -> MarkLifecycle
    {
        switch life {
        case "transient": return .transient
        case "step": return .stepBound
        case "speech": return .speechBound(group: group)
        default: break
        }
        switch shape {
        case .ring: return .transient
        case .stepBadge: return .stepBound
        case .highlight: return group == nil ? .transient : .speechBound(group: group)
        default: return .speechBound(group: group)
        }
    }
}

extension InkKind {
    public static func forShape(_ shape: AnnotationShape) -> InkKind {
        shape == .stepBadge ? .stepBadge : .emphasis
    }
}
