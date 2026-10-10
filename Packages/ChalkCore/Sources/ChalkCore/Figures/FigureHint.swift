import Foundation

/// A deterministic nudge for weak models (§7.4: routing rules are Swift, not a model): when the
/// learner asks to draw a shape, the prompt says to use a `geometry` figure. Flash Lite answered
/// "draw a hexagon" with algebra twice despite the rules (owner's hand test, D60).
public enum FigureHint: Equatable, Sendable {
    case geometry

    static let drawingVerbs: Set<String> = ["draw", "sketch", "show", "make", "construct", "plot"]
    /// "circle" is left out on purpose: "draw a circle around X" is an annotation.
    static let shapeWords: Set<String> = [
        "triangle", "triangles", "square", "squares", "rectangle", "rectangles", "pentagon",
        "hexagon", "heptagon", "octagon", "nonagon", "decagon", "polygon", "polygons",
        "quadrilateral", "parallelogram", "trapezium", "trapezoid", "rhombus", "kite",
    ]

    public static func forQuestion(_ question: String) -> FigureHint? {
        let words = Set(FuzzyTextMatch.normalized(question).split(separator: " ").map(String.init))
        guard !words.isDisjoint(with: drawingVerbs), !words.isDisjoint(with: shapeWords) else {
            return nil
        }
        return .geometry
    }

    public var contextLine: String {
        switch self {
        case .geometry:
            return """
                <context>
                The learner wants a shape drawn on the whiteboard. Answer with a figure of kind \
                "geometry" (for a regular polygon, "regular": n is enough; otherwise points and \
                segments), not math_steps. Add angle or side labels the question is about.
                </context>
                """
        }
    }
}
