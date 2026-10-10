import Foundation
import Testing

@testable import ChalkCore

@Suite("LaTeX math lines on the board (D61)")
struct LatexMathTests {
    static let color = "#FFB224"
    static func wrapped(_ text: String) -> String { "{\\textcolor{\(color)}{\(text)}}" }

    @Test("lines with LaTeX markup are recognised; plain words are not")
    func recognises() {
        #expect(LatexMath.looksLikeLatex(#"F(s) = \frac{1}{\sqrt{2\pi}}"#))
        #expect(LatexMath.looksLikeLatex("x^2 + y^2"))
        #expect(!LatexMath.looksLikeLatex("x = 0.999…"))
        #expect(!LatexMath.looksLikeLatex("Each interior angle = 120°"))
    }

    @Test("changed numbers and letters are coloured; the rest is copied as written")
    func highlightsChanges() {
        let line = LatexMath.highlightingChanges(
            from: #"x = 0.999\ldots"#, to: #"10x = 9.999\ldots"#, colorHex: Self.color)
        // Numbers are coloured digit by digit (SwiftMath crashes on a coloured multi-digit one).
        #expect(
            line == Self.wrapped("1") + Self.wrapped("0") + #"x = "# + Self.wrapped("9")
                + Self.wrapped(".") + Self.wrapped("9") + Self.wrapped("9") + Self.wrapped("9")
                + #"\ldots"#)
    }

    @Test("large operators are never coloured (SwiftMath crashes on them); Greek letters are")
    func onlyGlyphCommandsColoured() {
        let integral = LatexMath.highlightingChanges(
            from: #"a + \sum x"#, to: #"a + \int x"#, colorHex: Self.color)
        #expect(integral == #"a + \int x"#)
        let greek = LatexMath.highlightingChanges(
            from: #"a + \alpha"#, to: #"a + \beta"#, colorHex: Self.color)
        #expect(greek == #"a + "# + Self.wrapped(#"\beta"#))
    }

    @Test("inside a fraction only the changed argument is wrapped, never the command")
    func fractionSafe() {
        let line = LatexMath.highlightingChanges(
            from: #"\frac{1}{2}"#, to: #"\frac{1}{3}"#, colorHex: Self.color)
        #expect(line == #"\frac{1}{"# + Self.wrapped("3") + "}")
    }

    @Test("a changed exponent is wrapped as a group, so x^ stays valid")
    func scriptSafe() {
        let line = LatexMath.highlightingChanges(from: "x^2", to: "x^3", colorHex: Self.color)
        #expect(line == "x^" + Self.wrapped("3"))
    }

    @Test("nothing inside text arguments or after left-delimiters is wrapped")
    func textAndDelimitersSafe() {
        let text = LatexMath.highlightingChanges(
            from: #"\text{for } x"#, to: #"\text{when } x"#, colorHex: Self.color)
        #expect(text == #"\text{when } x"#)
        let delimiters = LatexMath.highlightingChanges(
            from: #"\left( a \right)"#, to: #"\left[ a \right]"#, colorHex: Self.color)
        #expect(delimiters == #"\left[ a \right]"#)
    }

    @Test("the first line has nothing to compare with")
    func firstLine() {
        #expect(LatexMath.highlightingChanges(from: nil, to: "x^2", colorHex: Self.color) == "x^2")
    }

    @Test("a line splits at its first top-level =, not one inside braces")
    func splitsAtEquals() throws {
        let split = try #require(LatexMath.splitAtTopLevelEquals(#"F(s) = \frac{1}{\sqrt{2\pi}}"#))
        #expect(split.left == "F(s)")
        #expect(split.right == #"\frac{1}{\sqrt{2\pi}}"#)
        let sum = try #require(LatexMath.splitAtTopLevelEquals(#"\sum_{i=1}^{n} i = 5"#))
        #expect(sum.left == #"\sum_{i=1}^{n} i"#)
        #expect(LatexMath.splitAtTopLevelEquals(#"\frac{a=b}{2}"#) == nil)
    }

    @Test("LaTeX written with single backslashes in JSON is repaired")
    func repairsEscapes() throws {
        // What JSON makes of "\frac{1}{2} + \text{ for } \beta" written with single backslashes.
        let broken = "\u{0C}rac{1}{2} + \u{09}ext{ for } \u{08}eta"
        #expect(MathStepsSpec.repairingLatexEscapes(broken) == #"\frac{1}{2} + \text{ for } \beta"#)
        // A real tab or newline before a non-letter is left alone.
        #expect(MathStepsSpec.repairingLatexEscapes("a\t1") == "a\t1")
    }

    @Test("a line that is mostly new is a new equation: nothing is highlighted")
    func newEquationNotHighlighted() {
        let line = #"F(s) = \frac{1}{\sqrt{2\pi}} \int f(x)\, dx"#
        #expect(
            LatexMath.highlightingChanges(from: "x = 1", to: line, colorHex: Self.color) == line)
    }

    @Test("spacing commands are never wrapped")
    func spacingNotWrapped() {
        let line = LatexMath.highlightingChanges(
            from: #"a\, b"#, to: #"a\, c"#, colorHex: Self.color)
        #expect(line == #"a\, "# + Self.wrapped("c"))
    }

    @Test("operators keep their spacing: the changed operand is coloured, not the operator")
    func operatorsNotWrapped() {
        let line = LatexMath.highlightingChanges(
            from: "x = 1", to: "x = 1 + 2", colorHex: Self.color)
        #expect(line == "x = 1 + " + Self.wrapped("2"))
    }

    @Test("tableaux become matrices SwiftMath can typeset (D72)")
    func compatible() {
        #expect(
            LatexMath.compatible(#"\begin{array}{c|ccc} x_1 & x_2 \\ \hline 1 & 0 \end{array}"#)
                == #"\begin{matrix} x_1 & x_2 \\  1 & 0 \end{matrix}"#)
        #expect(LatexMath.compatible(#"$Z = 3x_1 + 5x_2$"#) == "Z = 3x_1 + 5x_2")
        #expect(LatexMath.compatible(#"\$5 + x"#) == #"\$5 + x"#)
    }

    @Test("an equals sign inside a matrix doesn't split the line (D72)")
    func noSplitInsideMatrix() {
        #expect(LatexMath.splitAtTopLevelEquals(#"\begin{matrix} a = 1 \end{matrix}"#) == nil)
        #expect(
            LatexMath.splitAtTopLevelEquals(#"T = \begin{bmatrix} 1 & 0 \end{bmatrix}"#)?.left == "T")
    }
}
