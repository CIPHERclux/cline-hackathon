import CoreGraphics
import Foundation

/// One element of the front app's accessibility tree (D74): what macOS already knows about a
/// button or field, exactly, without a screenshot or a model. Frames are in global screen
/// coordinates with the origin at the top-left of the main display (Accessibility's own space).
public struct AccessibilityNode: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var frame: CGRect
    public var isFocused: Bool
    public var isSelected: Bool
    public var isEnabled: Bool

    public init(
        role: String, subrole: String? = nil, title: String? = nil, label: String? = nil,
        value: String? = nil, placeholder: String? = nil, frame: CGRect, isFocused: Bool = false,
        isSelected: Bool = false, isEnabled: Bool = true
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.frame = frame
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }

    /// The words that name it, best first: what a user (and the model) would call it.
    public var names: [String] {
        [title, label, placeholder, role == "AXStaticText" ? value : nil]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var hasText: Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The front app's tree at one moment.
public struct AccessibilitySnapshot: Equatable, Sendable {
    public var appName: String?
    public var bundleIdentifier: String?
    public var focusedWindowTitle: String?
    /// The page address in a browser (the web area's URL, or the address field's value).
    public var documentURL: String?
    public var nodes: [AccessibilityNode]

    public init(
        appName: String?, bundleIdentifier: String?, focusedWindowTitle: String?,
        documentURL: String?, nodes: [AccessibilityNode]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.focusedWindowTitle = focusedWindowTitle
        self.documentURL = documentURL
        self.nodes = nodes
    }

    public var focusedNode: AccessibilityNode? { nodes.first { $0.isFocused } }

    /// An app that exposes almost nothing (a canvas app, a game) can't be read; vision takes over.
    public var isUsable: Bool { nodes.count >= 5 }
}

/// What a plan step names (D74): "button Compose", "field Subject". Matched against the tree,
/// then OCR, then a model look, in that order.
public struct ElementQuery: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case button, field, link, menu
        case menuItem = "menu_item"
        case tab, checkbox, radio, popup, row,
            cell, image, text, window, any
    }

    public var role: Role
    public var name: String

    public init(role: Role, name: String) {
        self.role = role
        self.name = name
    }

    /// `{"role":"button","name":"Compose"}`; nil without a name.
    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        self.init(
            role: json["role"]?.stringValue.flatMap(Role.init(rawValue:)) ?? .any, name: name)
    }

    /// Accessibility roles each query role accepts.
    var acceptedRoles: Set<String> {
        switch role {
        case .button:
            return [
                "AXButton", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle", "AXLink",
                "AXDockItem",
            ]
        case .field:
            return [
                "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField",
            ]
        case .link: return ["AXLink", "AXButton"]
        case .menu: return ["AXMenuBarItem", "AXMenu", "AXMenuButton", "AXPopUpButton"]
        case .menuItem: return ["AXMenuItem", "AXMenuBarItem"]
        case .tab: return ["AXRadioButton", "AXTab", "AXButton"]
        case .checkbox: return ["AXCheckBox", "AXSwitch", "AXToggle"]
        case .radio: return ["AXRadioButton"]
        case .popup: return ["AXPopUpButton", "AXComboBox", "AXMenuButton"]
        case .row: return ["AXRow", "AXOutlineRow", "AXCell"]
        case .cell: return ["AXCell", "AXRow"]
        case .image: return ["AXImage", "AXButton", "AXDockItem"]
        case .text: return ["AXStaticText", "AXHeading"]
        case .window: return ["AXWindow", "AXSheet", "AXDialog"]
        case .any: return []
        }
    }
}

public enum AccessibilityMatcher {
    /// The element a query names, best first by: name match, role fit, enabled, on screen, then
    /// nearest `near` (the cursor, or the model's point).
    public static func bestMatch(
        for query: ElementQuery, in snapshot: AccessibilitySnapshot, visibleArea: CGRect?,
        near: CGPoint? = nil
    ) -> AccessibilityNode? {
        let accepted = query.acceptedRoles
        let scored = snapshot.nodes.compactMap { node -> (node: AccessibilityNode, score: Int)? in
            guard node.frame.width >= 2, node.frame.height >= 2 else { return nil }
            if let visibleArea, !visibleArea.intersects(node.frame) { return nil }
            guard
                let nameRank = node.names.compactMap({
                    FuzzyTextMatch.rank(candidate: $0, wanted: query.name)
                }).min()
            else { return nil }
            var score = nameRank * 10
            if !accepted.isEmpty && !accepted.contains(node.role) {
                // Static text that names a control (a label beside a field) is a weaker hit.
                score += node.role == "AXStaticText" ? 6 : 15
            }
            if !node.isEnabled { score += 8 }
            return (node, score)
        }
        return scored.min { first, second in
            if first.score != second.score { return first.score < second.score }
            guard let near else { return first.node.frame.area < second.node.frame.area }
            return first.node.frame.distance(to: near) < second.node.frame.distance(to: near)
        }?.node
    }

    /// The smallest named element containing a point (for snapping a model's guess).
    public static func smallestElement(
        containing point: CGPoint, in snapshot: AccessibilitySnapshot
    )
        -> AccessibilityNode?
    {
        snapshot.nodes
            .filter { $0.frame.contains(point) && $0.frame.width >= 6 && $0.frame.height >= 6 }
            .filter {
                $0.role != "AXWindow" && $0.role != "AXGroup" && $0.role != "AXScrollArea"
                    && $0.role != "AXWebArea"
            }
            .min { $0.frame.area < $1.frame.area }
    }
}

extension CGRect {
    var area: CGFloat { width * height }

    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}
