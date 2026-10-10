import CoreGraphics
import Foundation

/// Deterministic context added to a question (§7.4's spirit: rules in Swift, not a model). The
/// owner's hand test: on a page of several questions, "solve this question step by step" got a
/// different question solved, and solved wrongly. The model never knew where the pointer was,
/// and read small maths from a downscaled screenshot (D62).
public enum QuestionContext {
    static let workedSolutionPhrases = [
        "step by step", "the steps", "work out", "show me how", "how do i solve", "walk me through",
    ]
    static let workedSolutionWords: Set<String> = [
        "solve", "solving", "evaluate", "calculate", "compute", "derive", "prove", "integrate",
        "differentiate", "simplify",
    ]
    /// The crop around the pointer sent with a worked-solution question, in points.
    public static let pointerCropSizeInPoints = CGSize(width: 760, height: 520)

    public static func isWorkedSolution(_ question: String) -> Bool {
        let normalized = FuzzyTextMatch.normalized(question)
        if workedSolutionPhrases.contains(where: { normalized.contains($0) }) { return true }
        let words = Set(normalized.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: workedSolutionWords)
    }

    /// Where the pointer is, in the 0–1000 coordinates the model already points in.
    public static func pointerLine(cursorInNativePixels cursor: CGPoint, screenSpace: ScreenSpace)
        -> String
    {
        let model = screenSpace.nativePixelToModelPixel(cursor)
        let x = Int((model.x / screenSpace.modelPixelSize.width * 1000).rounded())
        let y = Int((model.y / screenSpace.modelPixelSize.height * 1000).rounded())
        return """
            <context>
            The learner's mouse pointer is at (\(x), \(y)) in 0-1000 screenshot coordinates. \
            "This", "here" and "this question" mean what is at or just below the pointer, not \
            something else on the screen.
            </context>
            """
    }

    public static func cropAroundPointer(
        cursorInNativePixels cursor: CGPoint, screenSpace: ScreenSpace
    )
        -> CGRect
    {
        ZoomPass.cropRect(
            around: cursor, screenSpace: screenSpace, sizeInPoints: pointerCropSizeInPoints)
    }

    public static let workedSolutionLine = """
        <context>
        The learner asked for a worked solution. First read the exact question they mean (if \
        there is a second image, it is that area at full resolution: copy the question from it \
        carefully, every sign, power and limit). Then solve it step by step, checking each step \
        before the next, and write the working on the whiteboard as math_steps, one line per \
        step. Speak one short sentence per step. Take as many steps as it needs.
        </context>
        """
}
