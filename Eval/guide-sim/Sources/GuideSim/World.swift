import ChalkCore
import CoreGraphics
import Foundation

// A scripted Mac screen: named states, each a set of controls with frames; clicks, keys and
// typing move between states. Field values and focus carry across states by field name.

struct ScenarioNode: Decodable {
    var role: String
    var subrole: String?
    var title: String?
    var label: String?
    var value: String?
    var placeholder: String?
    var frame: [Double]
    var enabled: Bool?
    var selected: Bool?
    /// Typable: its value lives in the world's values by name.
    var field: Bool?
    /// State to go to when clicked.
    var click: String?
    /// For fields: state to go to on Return.
    var onReturn: String?
    /// For fields: go to `goto` once the typed value contains `contains`.
    var onType: [TypeRule]?
    /// A click here also sets a field ("pick Paris in the suggestions" fills the To field).
    var sets: [String: String]?

    struct TypeRule: Decodable {
        var contains: String
        var goto: String
    }

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, label, value, placeholder, frame, enabled, selected, field,
            click, sets
        case onReturn = "on_return"
        case onType = "on_type"
    }

    var rect: CGRect { CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) }
    var name: String { title ?? label ?? placeholder ?? value ?? role }
}

struct ScenarioState: Decodable {
    var inherit: String?
    var app: String?
    var bundle: String?
    var window: String?
    var url: String?
    /// False: the app exposes no tree (DaVinci); the guide sees OCR words only.
    var accessible: Bool?
    var nodes: [ScenarioNode]?
    /// Node names removed from the inherited state.
    var remove: [String]?
    var keys: [String: String]?
    var focus: String?
    /// Shown as `loadingState` for this long after entering (a page loading).
    var loadingMs: Int?
    var loadingState: String?
    /// Field values set on entering.
    var sets: [String: String]?

    enum CodingKeys: String, CodingKey {
        case inherit, app, bundle, window, url, accessible, nodes, remove, keys, focus, sets
        case loadingMs = "loading_ms"
        case loadingState = "loading_state"
    }
}

struct Deviation: Decodable {
    /// Before acting on this step number (1-based), the user does these instead.
    var step: Int
    var actions: [SimAction]
    var comment: String?
}

/// What the simulated user can do.
struct SimAction: Decodable {
    var click: String?
    var type: String?
    var into: String?
    var key: String?
    var say: String?
    var wait: Double?
    /// Then do what Chalk asked, as usual.
    var followChalk: Bool?
    var switchApp: String?
    var backAfter: Double?

    enum CodingKeys: String, CodingKey {
        case click, type, into, key, say, wait
        case followChalk = "follow_chalk"
        case switchApp = "switch_app"
        case backAfter = "back_after"
    }
}

struct Scenario: Decodable {
    var name: String
    var goal: String
    var start: String
    var goalState: [String]
    var values: [String: String]?
    /// How the user finishes typing: tab, return, click_next, idle.
    var commit: String?
    var answers: [String: String]?
    var deviations: [Deviation]?
    var dock: [ScenarioNode]?
    var states: [String: ScenarioState]
    var maxSeconds: Double?
    var openApps: [String]?
    var expectations: Expectations?

    struct Expectations: Decodable {
        var maxSteps: Int?
        var expectQuestion: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case name, goal, start, values, commit, answers, deviations, dock, states, expectations
        case goalState = "goal_state"
        case maxSeconds = "max_seconds"
        case openApps = "open_apps"
    }
}

@MainActor
final class SimWorld {
    let scenario: Scenario
    private(set) var stateName: String
    private(set) var enteredAt = Date()
    var values: [String: String] = [:]
    var focusedField: String?
    /// Another app in front (the user wandered off).
    var awayApp: String?
    private(set) var visited: [String] = []
    var onChange: (() -> Void)?

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    init(scenario: Scenario) {
        self.scenario = scenario
        stateName = scenario.start
        visited = [scenario.start]
        enter(scenario.start)
    }

    var reachedGoal: Bool { visited.contains { scenario.goalState.contains($0) } }

    func resolved(_ name: String) -> ScenarioState {
        guard var state = scenario.states[name] else { fatalError("no state \(name)") }
        if let parentName = state.inherit {
            let parent = resolved(parentName)
            let removed = Set(state.remove ?? [])
            let replacing = Set((state.nodes ?? []).map(\.name))
            let inherited = (parent.nodes ?? []).filter {
                !removed.contains($0.name) && !replacing.contains($0.name)
            }
            state.nodes = inherited + (state.nodes ?? [])
            state.app = state.app ?? parent.app
            state.bundle = state.bundle ?? parent.bundle
            state.window = state.window ?? parent.window
            state.url = state.url ?? parent.url
            state.accessible = state.accessible ?? parent.accessible
            var keys = parent.keys ?? [:]
            for (key, value) in state.keys ?? [:] { keys[key] = value }
            state.keys = keys
        }
        return state
    }

    /// The state the screen shows now (a loading page shows its loading state for a moment).
    var visibleStateName: String {
        let state = resolved(stateName)
        if let loading = state.loadingMs, let loadingState = state.loadingState,
            Date().timeIntervalSince(enteredAt) * 1000 < Double(loading)
        {
            return loadingState
        }
        return stateName
    }

    var isLoading: Bool { visibleStateName != stateName }

    func enter(_ name: String) {
        stateName = name
        enteredAt = Date()
        visited.append(name)
        let state = resolved(name)
        for (field, value) in state.sets ?? [:] { values[field] = value }
        if let focus = state.focus { focusedField = focus }
        onChange?()
    }

    var currentNodes: [ScenarioNode] { resolved(visibleStateName).nodes ?? [] }

    var appName: String { awayApp ?? resolved(visibleStateName).app ?? "Finder" }
    var bundleIdentifier: String {
        if let awayApp { return "sim.\(awayApp.lowercased())" }
        return resolved(visibleStateName).bundle ?? "com.apple.finder"
    }

    func node(named name: String) -> ScenarioNode? {
        let all = currentNodes + (scenario.dock ?? [])
        return all.first { FuzzyTextMatch.normalized($0.name) == FuzzyTextMatch.normalized(name) }
            ?? all.first { (FuzzyTextMatch.rank(candidate: $0.name, wanted: name) ?? 9) <= 2 }
    }

    /// The smallest actionable node at a point (what a click there hits).
    func node(at point: CGPoint) -> ScenarioNode? {
        (currentNodes + (scenario.dock ?? [])).filter {
            $0.rect.contains(point) && ($0.click != nil || $0.field == true)
        }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    // MARK: Acting

    @discardableResult
    func click(_ node: ScenarioNode) -> Bool {
        guard awayApp == nil, node.enabled != false else { return false }
        for (field, value) in node.sets ?? [:] { values[field] = value }
        if node.field == true { focusedField = node.name }
        if let target = node.click {
            enter(target)
        } else {
            onChange?()
        }
        return true
    }

    func type(_ text: String) {
        guard let field = focusedField else { return }
        values[field] = text
        if let node = currentNodes.first(where: { $0.name == field }) {
            for rule in node.onType ?? []
            where text.localizedCaseInsensitiveContains(rule.contains) {
                enter(rule.goto)
                return
            }
        }
        onChange?()
    }

    func pressReturn() {
        if let field = focusedField, let node = currentNodes.first(where: { $0.name == field }),
            let target = node.onReturn
        {
            enter(target)
        } else {
            onChange?()
        }
    }

    /// Moves focus to the next field down the screen.
    func pressTab() {
        let fields = currentNodes.filter { $0.field == true }.sorted {
            ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX)
        }
        if let index = fields.firstIndex(where: { $0.name == focusedField }),
            index + 1 < fields.count
        {
            focusedField = fields[index + 1].name
        } else {
            focusedField = nil
        }
        onChange?()
    }

    func pressKeys(_ combo: String) -> Bool {
        let normalized = combo.lowercased().replacingOccurrences(of: " ", with: "")
        guard let target = resolved(stateName).keys?.first(where: {
            $0.key.lowercased().replacingOccurrences(of: " ", with: "") == normalized
        })?.value else { return false }
        enter(target)
        return true
    }

    // MARK: Observing

    func snapshot() -> AccessibilitySnapshot {
        let state = resolved(visibleStateName)
        if awayApp != nil || state.accessible == false {
            return AccessibilitySnapshot(
                appName: appName, bundleIdentifier: bundleIdentifier,
                focusedWindowTitle: awayApp == nil ? state.window : awayApp, documentURL: nil,
                nodes: [])
        }
        let nodes = currentNodes.map { node -> AccessibilityNode in
            let value = node.field == true ? values[node.name] ?? node.value : node.value
            return AccessibilityNode(
                role: node.role, subrole: node.subrole, title: node.title, label: node.label,
                value: value, placeholder: node.placeholder, frame: node.rect,
                isFocused: node.field == true && node.name == focusedField,
                isSelected: node.selected ?? false, isEnabled: node.enabled ?? true)
        }
        return AccessibilitySnapshot(
            appName: appName, bundleIdentifier: bundleIdentifier, focusedWindowTitle: state.window,
            documentURL: state.url, nodes: nodes)
    }

    /// OCR words for apps without a tree.
    func visibleTexts() -> [GuideVisibleText] {
        let state = resolved(visibleStateName)
        guard awayApp == nil, state.accessible == false else { return [] }
        return currentNodes.compactMap { node in
            let text = node.field == true ? values[node.name] ?? node.name : node.name
            return text.isEmpty ? nil : GuideVisibleText(text: text, frame: node.rect)
        }
    }
}
