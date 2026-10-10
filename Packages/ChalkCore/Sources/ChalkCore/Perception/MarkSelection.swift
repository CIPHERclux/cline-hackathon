import CoreGraphics
import Foundation

/// Turns raw candidates into numbered marks (§6.2 b): merge, NMS, prioritize, cap.
///
/// Measured in the D40 pointing check: with text first and a 120 cap, dense screens (DaVinci
/// Resolve) filled the cap with text and icon-only controls got no mark. So text is capped
/// separately and icon-sized shapes keep room; mark recall on real screens went 9/19 → 15/19.
public enum MarkSelection {
    public struct Limits: Sendable {
        public var maximumMarks: Int
        public var maximumTextMarks: Int

        /// §6.2 b says ≤ 120 marks; the D40 experiment used 150 / 100 text to leave room for icons.
        /// The cap only exists so a tagged image stays readable for the model (set-of-marks mode).
        public static let standard = Limits(maximumMarks: 150, maximumTextMarks: 100)
        /// Snap targets are never shown to the model, so they aren't capped: on dense screens
        /// (DaVinci Resolve) small toolbar icons only survive uncapped (S05, D48).
        public static let unlimited = Limits(maximumMarks: .max, maximumTextMarks: .max)

        public init(maximumMarks: Int, maximumTextMarks: Int) {
            self.maximumMarks = maximumMarks
            self.maximumTextMarks = maximumTextMarks
        }
    }

    /// - Parameters:
    ///   - focusRect: the frontmost window in native pixels; candidates inside it win when the cap
    ///     bites (§6.2 b "prioritized … inside the frontmost window").
    ///   - cursor: native pixels; nearer candidates win next (§6.2 b "near the cursor").
    /// Shapes up to this size (native px) count as icon-sized and win the cap first.
    static let iconMaximumSide: CGFloat = 96

    public static func selectMarks(
        from candidates: [Candidate], limits: Limits = .standard, focusRect: CGRect? = nil,
        cursor: CGPoint? = nil
    ) -> [Mark] {
        func priority(_ candidate: Candidate) -> (Int, CGFloat) {
            let isInsideFocus = focusRect.map { candidate.box.fractionInside($0) > 0.5 } ?? true
            let distance =
                cursor.map { hypot(candidate.box.midX - $0.x, candidate.box.midY - $0.y) } ?? 0
            return (isInsideFocus ? 0 : 1, distance)
        }

        // Text first: exact labels. Without a focus or cursor, shorter lines first, because long
        // lines are body text rather than controls.
        let textCandidates = candidates.filter { $0.kind == .text }.sorted { first, second in
            let firstPriority = priority(first)
            let secondPriority = priority(second)
            if firstPriority != secondPriority { return firstPriority < secondPriority }
            return (first.text ?? "").count < (second.text ?? "").count
        }
        // Then contour shapes (the icons) before rectangles (often whole panels), larger first
        // within each kind so an icon's outline wins over its inner strokes (S05: on DaVinci the
        // cap otherwise filled with panel rectangles and dropped two toolbar icons).
        let otherCandidates = candidates.filter { $0.kind != .text }.sorted { first, second in
            let firstPriority = priority(first)
            let secondPriority = priority(second)
            if firstPriority.0 != secondPriority.0 { return firstPriority.0 < secondPriority.0 }
            if first.kind != second.kind { return first.kind == .shape }
            // Icon-sized shapes (≤ 96 px, 48 pt on Retina) before bigger blobs such as thumbnails.
            let firstIsIconSized = max(first.box.width, first.box.height) <= iconMaximumSide
            let secondIsIconSized = max(second.box.width, second.box.height) <= iconMaximumSide
            if firstIsIconSized != secondIsIconSized { return firstIsIconSized }
            return first.box.width * first.box.height > second.box.width * second.box.height
        }

        var accepted: [Candidate] = []
        for candidate in textCandidates where accepted.count < limits.maximumTextMarks {
            if accepted.contains(where: { $0.box.intersectionOverUnion(with: candidate.box) > 0.6 })
            {
                continue
            }
            accepted.append(candidate)
        }
        for candidate in otherCandidates where accepted.count < limits.maximumMarks {
            if accepted.contains(where: { $0.box.intersectionOverUnion(with: candidate.box) > 0.6 })
            {
                continue
            }
            // Glyph outlines inside a text label, and inner strokes inside an accepted icon.
            if accepted.contains(where: {
                $0.kind == .text && candidate.box.fractionInside($0.box) > 0.5
            }) {
                continue
            }
            if accepted.contains(where: {
                $0.kind != .text && $0.box.width <= 160
                    && candidate.box.fractionInside($0.box) > 0.8
            }) {
                continue
            }
            accepted.append(candidate)
        }

        // Stable reading-order ids: top-to-bottom in 20 px bands, then left-to-right.
        let ordered = accepted.sorted {
            (Int($0.box.minY / 20), $0.box.minX) < (Int($1.box.minY / 20), $1.box.minX)
        }
        return ordered.enumerated().map { index, candidate in
            Mark(id: index + 1, kind: candidate.kind, text: candidate.text, box: candidate.box)
        }
    }

    /// The smallest control-sized mark (≤ 400 px a side) under a point: the "snap" step that turns
    /// a model's raw point into an exact outline (D40: kept every raw hit on real screens).
    public static func smallestMark(
        containing point: CGPoint, in marks: [Mark], maximumSide: CGFloat = 400
    ) -> Mark? {
        marks
            .filter {
                $0.box.contains(point) && $0.box.width <= maximumSide
                    && $0.box.height <= maximumSide
            }
            .min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    /// Compact text list for prompts: `m17 text "Auto layout" (1180,212)` in model pixels (§6.2 c).
    public static func promptList(for marks: [Mark], screenSpace: ScreenSpace) -> String {
        marks.map { mark in
            let center = screenSpace.nativePixelToModelPixel(mark.center)
            let label =
                mark.text.map { " \"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""
            return
                "m\(mark.id) \(mark.kind.rawValue)\(label) (\(Int(center.x.rounded())),\(Int(center.y.rounded())))"
        }.joined(separator: "\n")
    }
}
