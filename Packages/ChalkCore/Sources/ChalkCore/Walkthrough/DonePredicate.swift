import Foundation

/// When a walkthrough step is done, in terms the app can check itself (D74): the plan says
/// `{"value_not_empty":"Subject"}` and the app reads it from the accessibility tree the moment
/// the user types, with no screenshot and no model. `evaluate` returns nil when it can't tell
/// (the app exposes no tree, or the predicate needs a screen it doesn't have); then a quick model
/// check decides.
public indirect enum DonePredicate: Equatable, Sendable {
    /// The focused element is the one named.
    case focused(String)
    /// The named field has any text, or contains `text`.
    case valueNotEmpty(String)
    case valueContains(name: String, text: String)
    /// Something with that name (an element, a window, a dialog) is there, or isn't.
    case exists(String)
    case gone(String)
    /// The front window's title contains it.
    case window(String)
    /// The named option is selected or checked, or a pop-up now shows it.
    case selected(String)
    /// That app is in front.
    case app(String)
    /// The browser's page address contains it.
    case url(String)
    /// The words are visible on screen (accessibility names, else OCR).
    case text(String)
    case all([DonePredicate])
    case any([DonePredicate])

    /// Parses `{"focused":"Subject"}`, `{"all":[…]}` and the rest; nil for anything else.
    public init?(json: JSONValue) {
        guard case .object(let fields) = json, let (key, value) = fields.first, fields.count == 1
        else { return nil }
        switch key {
        case "all", "any":
            guard let values = value.arrayValue else { return nil }
            let parts = values.compactMap(DonePredicate.init(json:))
            guard !parts.isEmpty, parts.count == values.count else { return nil }
            self = key == "all" ? .all(parts) : .any(parts)
        case "value_contains":
            guard let name = value["name"]?.stringValue, let text = value["text"]?.stringValue
            else { return nil }
            self = .valueContains(name: name, text: text)
        default:
            guard let argument = value.stringValue?.trimmingCharacters(in: .whitespaces),
                !argument.isEmpty
            else { return nil }
            switch key {
            case "focused": self = .focused(argument)
            case "value_not_empty": self = .valueNotEmpty(argument)
            case "exists": self = .exists(argument)
            case "gone": self = .gone(argument)
            case "window": self = .window(argument)
            case "selected": self = .selected(argument)
            case "app": self = .app(argument)
            case "url": self = .url(argument)
            case "text": self = .text(argument)
            default: return nil
            }
        }
    }

    /// `frontmostAppName` comes from the workspace (it doesn't need the tree); `visibleTexts`
    /// are OCR lines when a screenshot was read, else nil.
    public func evaluate(
        snapshot: AccessibilitySnapshot?, frontmostAppName: String?, visibleTexts: [String]?
    ) -> Bool? {
        func matches(_ text: String?, _ wanted: String) -> Bool {
            guard let text, !text.isEmpty else { return false }
            guard let rank = FuzzyTextMatch.rank(candidate: text, wanted: wanted) else {
                return false
            }
            if rank == 0 { return true }
            guard rank <= 2 else { return false }
            // Prefixes and "contains" must be whole words: "To" is not "Today" or "October".
            let candidateWords = " \(FuzzyTextMatch.normalized(text)) "
            let wantedWords = " \(FuzzyTextMatch.normalized(wanted)) "
            return candidateWords.contains(wantedWords) || wantedWords.contains(candidateWords)
        }
        func named(_ name: String) -> [AccessibilityNode] {
            snapshot?.nodes.filter { node in node.names.contains { matches($0, name) } } ?? []
        }
        let usable = snapshot?.isUsable == true
        switch self {
        case .app(let name):
            guard let frontmostAppName else { return nil }
            return matches(frontmostAppName, name)
        case .focused(let name):
            guard usable else { return nil }
            guard let focused = snapshot?.focusedNode else { return false }
            return focused.names.contains { matches($0, name) }
        case .valueNotEmpty(let name):
            guard usable else { return nil }
            let candidates = named(name).filter { $0.role != "AXStaticText" }
            // No named field is not evidence about an unrelated focused field.
            if candidates.isEmpty { return nil }
            return candidates.contains { $0.hasText }
        case .valueContains(let name, let text):
            guard usable else { return nil }
            return named(name).contains { $0.value?.localizedCaseInsensitiveContains(text) == true }
        case .exists(let name):
            if usable, !named(name).isEmpty || matches(snapshot?.focusedWindowTitle, name) {
                return true
            }
            if let visibleTexts { return visibleTexts.contains { matches($0, name) } }
            return usable ? false : nil
        case .gone(let name):
            guard usable else { return nil }
            return named(name).isEmpty && !matches(snapshot?.focusedWindowTitle, name)
        case .window(let title):
            guard let windowTitle = snapshot?.focusedWindowTitle else {
                return usable ? false : nil
            }
            return windowTitle.localizedCaseInsensitiveContains(title)
                || matches(windowTitle, title)
        case .selected(let name):
            guard usable else { return nil }
            return snapshot?.nodes.contains { node in
                let isNamed = node.names.contains { matches($0, name) }
                let showsIt =
                    ["AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(node.role)
                    && matches(node.value, name)
                return (isNamed && (node.isSelected || node.value == "1")) || showsIt
            } ?? false
        case .url(let fragment):
            guard let url = snapshot?.documentURL else { return usable ? false : nil }
            return url.localizedCaseInsensitiveContains(fragment)
        case .text(let words):
            if usable, !named(words).isEmpty { return true }
            // What's typed in a field is on screen too.
            if usable,
                snapshot?.nodes.contains(where: {
                    $0.role != "AXSecureTextField"
                        && $0.value?.localizedCaseInsensitiveContains(words) == true
                }) == true
            {
                return true
            }
            if let visibleTexts { return visibleTexts.contains { matches($0, words) } }
            return usable ? false : nil
        case .all(let parts):
            let results = parts.map {
                $0.evaluate(
                    snapshot: snapshot, frontmostAppName: frontmostAppName,
                    visibleTexts: visibleTexts)
            }
            if results.contains(false) { return false }
            return results.contains(nil) ? nil : true
        case .any(let parts):
            let results = parts.map {
                $0.evaluate(
                    snapshot: snapshot, frontmostAppName: frontmostAppName,
                    visibleTexts: visibleTexts)
            }
            if results.contains(true) { return true }
            return results.contains(nil) ? nil : false
        }
    }
}
