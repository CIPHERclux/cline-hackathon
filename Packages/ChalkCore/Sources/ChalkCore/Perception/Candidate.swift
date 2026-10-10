import CoreGraphics
import Foundation

/// Something on screen that might be a target (§6.2 b): an OCR'd text line, a detected
/// rectangle, or a contour blob (icon-like shape). Boxes are in native pixels, top-left origin.
public struct Candidate: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, box, shape
    }

    public var kind: Kind
    public var text: String?
    public var box: CGRect
    public var confidence: Double

    public init(kind: Kind, text: String? = nil, box: CGRect, confidence: Double = 1) {
        self.kind = kind
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

extension Mark {
    /// Marks from the accessibility tree are numbered from here (D74): their frames are exact,
    /// so they skip the OCR re-check after drawing (an icon button has no text to re-read).
    public static let accessibilityIdentifierBase = 100_000

    public var isFromAccessibility: Bool { id >= Self.accessibilityIdentifierBase }
}

/// A numbered candidate the model and the renderer can refer to (`{"mark": 17}`, §6.4).
public struct Mark: Codable, Equatable, Sendable {
    public var id: Int
    public var kind: Candidate.Kind
    public var text: String?
    /// Native pixels: x, y, width, height (top-left origin).
    public var box: CGRect

    public init(id: Int, kind: Candidate.Kind, text: String?, box: CGRect) {
        self.id = id
        self.kind = kind
        self.text = text
        self.box = box
    }

    public var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    // `box` is stored as [x, y, width, height], the format the harness and tools read.
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, box
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        kind = try container.decode(Candidate.Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        let values = try container.decode([Double].self, forKey: .box)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .box, in: container, debugDescription: "box needs 4 numbers")
        }
        box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(
            [box.minX, box.minY, box.width, box.height].map(Double.init), forKey: .box)
    }
}

extension CGRect {
    func intersectionOverUnion(with other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return 0 }
        let overlapArea = overlap.width * overlap.height
        return overlapArea / (width * height + other.width * other.height - overlapArea)
    }

    /// Share of this rect's area that lies inside `other`.
    func fractionInside(_ other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        guard !overlap.isNull, width > 0, height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (width * height)
    }
}
