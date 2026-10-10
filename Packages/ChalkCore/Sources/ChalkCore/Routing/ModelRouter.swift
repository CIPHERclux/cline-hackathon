import Foundation

/// The model slots of §7.4.
public enum ModelSlot: String, Sendable, CaseIterable {
    case fast, teaching, grounding, deep
}

/// `Sidecar/model-routing.json`, shared with tutor-engine so model IDs live in one config file
/// (§7.4: "slots are config, not code").
public struct ModelRoutingConfiguration: Decodable, Sendable {
    public struct SlotModels: Decodable, Sendable {
        public var primary: String
        public var fallbacks: [String]
    }

    public struct Profile: Decodable, Sendable {
        public var providerId: String
        public var slots: [String: SlotModels]
        /// Models that proved they can read screenshots (S02 S1 probe). Screenshots go only to
        /// these (§7.4 capability guard, P-NOVISION).
        public var vision: [String]?
    }

    public var defaultProfile: String
    public var profiles: [String: Profile]

    public static func load(from url: URL) throws -> ModelRoutingConfiguration {
        try JSONDecoder().decode(ModelRoutingConfiguration.self, from: Data(contentsOf: url))
    }
}

/// Deterministic per-turn routing (§7.4 "Router rules"; no on-device model decides).
public struct ModelRouter: Sendable {
    public enum RoutingError: Error, Equatable {
        case unknownProfile(String)
        case unknownSlot(ModelSlot)
        /// No model in the slot can read screenshots, so an image turn must not be sent there.
        case noVisionModel(ModelSlot)
    }

    /// Rule 1: a figure or proof request, or "go deeper", goes to the deep slot.
    static let deepKeywords = ["draw", "diagram", "graph", "prove", "derive", "go deeper", "plan"]
    /// Rule 3: a follow-up of this many words or fewer goes to the fast slot.
    static let shortFollowUpMaximumWordCount = 8

    public let configuration: ModelRoutingConfiguration
    public let profileName: String

    public init(configuration: ModelRoutingConfiguration, profileName: String? = nil) {
        self.configuration = configuration
        self.profileName = profileName ?? configuration.defaultProfile
    }

    /// Picks the slot for one learner turn (§7.4 rules 1–3; rule 4, parallel grounding, comes
    /// with marks in S05/S08).
    public static func slot(forTranscript transcript: String, isFollowUp: Bool) -> ModelSlot {
        let lowercasedTranscript = transcript.lowercased()
        let words = lowercasedTranscript.split(whereSeparator: {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        })
        let wordSet = Set(words.map(String.init))
        for keyword in deepKeywords {
            let isMatch =
                keyword.contains(" ")
                ? lowercasedTranscript.contains(keyword) : wordSet.contains(keyword)
            if isMatch { return .deep }
        }
        if isFollowUp && words.count <= shortFollowUpMaximumWordCount {
            return .fast
        }
        return .teaching
    }

    /// The models to try for a slot, in order: primary, then fallbacks (§7.4 rule 5). For a turn
    /// with a screenshot, models outside the vision list are skipped: the SDK would silently swap
    /// the image for "[Image attached — this model cannot view images]" (§7.4 capability guard).
    public func candidateModels(for slot: ModelSlot, requiresVision: Bool) throws -> [String] {
        guard let profile = configuration.profiles[profileName] else {
            throw RoutingError.unknownProfile(profileName)
        }
        guard let slotModels = profile.slots[slot.rawValue] else {
            throw RoutingError.unknownSlot(slot)
        }
        let allModels = [slotModels.primary] + slotModels.fallbacks
        guard requiresVision else { return allModels }
        let visionModels = Set(profile.vision ?? [])
        let usableModels = allModels.filter(visionModels.contains)
        guard !usableModels.isEmpty else { throw RoutingError.noVisionModel(slot) }
        return usableModels
    }
}
