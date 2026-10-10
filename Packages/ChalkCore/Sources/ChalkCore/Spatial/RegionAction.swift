import Foundation

/// What to do with a region the user lassoed and let go of without speaking (§4.2.5, §4.3
/// "Explain / summarise / translate this region"). Picked from a chooser next to the lasso.
public enum RegionAction: String, CaseIterable, Sendable {
    case explain, summarise, translate

    public var title: String {
        switch self {
        case .explain: return "Explain"
        case .summarise: return "Summarise"
        case .translate: return "Translate"
        }
    }

    /// `targetLanguage` is the user's language name ("English"), for translate.
    public func prompt(targetLanguage: String) -> String {
        switch self {
        case .explain:
            return
                "Explain what's in the region I circled: what it is, what it means and the key point, pointing at its parts as you explain."
        case .summarise:
            return
                "Summarise what's in the region I circled in two or three spoken sentences: the main point first, then anything I should notice. Underline the one line that matters most."
        case .translate:
            return
                "Translate the text in the region I circled into \(targetLanguage). Say the translation naturally, sentence by sentence; if it is already in \(targetLanguage), say what language it's in and summarise it instead. Mention any phrase that doesn't translate directly."
        }
    }
}
