/// Where an action points or draws (§6.4 "Target descriptor"). The model names targets, never
/// pixels unless it has to; the grounding layer resolves them in this order (§6.2):
/// mark → text → region → relative → px (last resort, low confidence).
public indirect enum TargetDescriptor: Equatable, Sendable {
    case mark(id: Int)
    case text(String, near: TargetDescriptor?, within: String?)
    case region(NormalizedRect, space: String?)
    case relative(of: TargetDescriptor, position: RelativePosition, gap: Double?)
    case pixel(x: Double, y: Double, space: String?)

    /// Raw pixel targets are flagged low-confidence: the model guessed coordinates instead of
    /// naming something we can verify (§6.2 resolution order, rule 5).
    public var isLowConfidence: Bool {
        switch self {
        case .pixel: return true
        case .relative(let anchor, _, _): return anchor.isLowConfidence
        case .text(_, let near, _): return near?.isLowConfidence ?? false
        case .mark, .region: return false
        }
    }

    /// Parses one descriptor object; nil when it matches none of the five shapes.
    public init?(json: JSONValue) {
        if let markIdentifier = json["mark"]?.integerValue {
            self = .mark(id: markIdentifier)
        } else if let text = json["text"]?.stringValue, !text.isEmpty {
            let near = json["near"].flatMap(TargetDescriptor.init(json:))
            self = .text(text, near: near, within: json["within"]?.stringValue)
        } else if let region = json["region"], let rectangle = NormalizedRect(json: region) {
            self = .region(rectangle, space: json["space"]?.stringValue)
        } else if let relative = json["relative"],
            let anchorJSON = relative["of"], let anchor = TargetDescriptor(json: anchorJSON),
            let positionName = relative["pos"]?.stringValue,
            let position = RelativePosition(rawValue: positionName)
        {
            self = .relative(of: anchor, position: position, gap: relative["gap"]?.numberValue)
        } else if let coordinates = json["px"]?.arrayValue, coordinates.count == 2,
            let x = coordinates[0].numberValue, let y = coordinates[1].numberValue
        {
            self = .pixel(x: x, y: y, space: json["space"]?.stringValue)
        } else {
            return nil
        }
    }
}

/// A rectangle in 0…1 coordinates of a named space (usually the frontmost window).
public struct NormalizedRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init?(json: JSONValue) {
        guard let x = json["x"]?.numberValue, let y = json["y"]?.numberValue,
            let width = json["w"]?.numberValue, let height = json["h"]?.numberValue,
            width > 0, height > 0
        else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }
}

public enum RelativePosition: String, Equatable, Sendable {
    case above, below, left, right
}
