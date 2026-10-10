import Foundation

/// LaTeX math lines for the whiteboard (D61, replacing D25's plain text at the owner's request:
/// "it should write equations as math, subscripts and all"). Pure string work: what changed
/// since the previous line is wrapped in `{\textcolor{#hex}{…}}` for the renderer, but only around
/// tokens where that is always valid LaTeX, so a highlight can never break a line. Operators and
/// relations are never wrapped: alone in a coloured group they lose their spacing (`\color` lost
/// it on both sides, which is why `\textcolor` is used), so the changed operands carry it.
public enum LatexMath {
    struct Token: Equatable {
        enum Kind: Equatable {
            case command, number, letter, symbol
        }

        var text: String
        var kind: Kind
        var range: Range<String.Index>
    }

    /// Commands that take arguments or shape what follows: never wrapped themselves.
    static let structuralCommands: Set<String> = [
        "\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\binom", "\\left", "\\right", "\\begin",
        "\\end",
        "\\color", "\\textcolor", "\\colorbox", "\\overline", "\\underline", "\\hat", "\\bar",
        "\\vec", "\\dot", "\\ddot", "\\tilde", "\\widehat", "\\overrightarrow", "\\limits",
        "\\displaystyle", "\\textstyle", "\\mathbb", "\\mathcal", "\\mathbf", "\\mathrm", "\\text",
        "\\textbf", "\\operatorname", "\\big", "\\Big", "\\bigg", "\\Bigg",
    ]
    /// Commands whose `{…}` argument is text or a name: nothing inside is wrapped.
    static let textArgumentCommands: Set<String> = [
        "\\text", "\\textbf", "\\mathrm", "\\mathbf", "\\operatorname", "\\mathbb", "\\mathcal",
        "\\begin", "\\end", "\\color", "\\textcolor", "\\colorbox",
    ]
    /// The only commands that may be coloured: single glyphs and function names. SwiftMath's
    /// `\textcolor` spacing code crashes on a large operator (`\int`, `\sum`) inside the group
    /// (probed with SwiftMath 1.7.3, D61), so everything else is left alone.
    static let colourableCommands: Set<String> = {
        let greek = [
            "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
            "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "varpi", "rho", "sigma",
            "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta",
            "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        ]
        let others = [
            "infty", "partial", "nabla", "ell", "hbar", "ldots", "cdots", "dots", "prime", "sin",
            "cos", "tan", "sec", "csc", "cot", "log", "ln", "exp",
        ]
        return Set((greek + others).map { "\\" + $0 })
    }()
    /// Spacing commands: wrapping them changes nothing visible.
    static let spacingCommands: Set<String> = [
        "\\,", "\\;", "\\:", "\\!", "\\quad", "\\qquad", "\\ ",
    ]
    /// Above this share of changed tokens the line is a new equation, not a step from the last
    /// one, and nothing is highlighted (otherwise almost all of it turns orange).
    static let largestHighlightedShare = 0.6
    /// Binary operators and relations (as symbols or commands): never wrapped.
    static let operatorTokens: Set<String> = [
        "+", "-", "=", "<", ">", "−", "×", "÷", "±", "≤", "≥", "≠", "≈", "→", "\\times", "\\cdot",
        "\\pm", "\\mp", "\\div", "\\le", "\\ge", "\\leq", "\\geq", "\\neq", "\\approx",
        "\\equiv", "\\to", "\\rightarrow", "\\Rightarrow", "\\implies", "\\iff", "\\sim",
    ]
    /// Symbols that are LaTeX syntax rather than content.
    static let syntaxSymbols: Set<String> = ["{", "}", "^", "_", "&", "$", "'", "\\\\"]

    /// Rewrites what SwiftMath can't typeset into what it can (D72): a simplex tableau written as
    /// `\begin{array}{c|ccc}` with `\hline` came out as raw text. Arrays and tabulars become
    /// `matrix` (SwiftMath has matrix, pmatrix, bmatrix…, no array), table rules go, and stray
    /// `$` delimiters are dropped.
    public static func compatible(_ latex: String) -> String {
        var result = latex
        let replacements: [(pattern: String, template: String)] = [
            (#"\\begin\{(array|tabular)\}(\[[^\]]*\])?\{[^}]*\}"#, #"\\begin{matrix}"#),
            (#"\\end\{(array|tabular)\}"#, #"\\end{matrix}"#),
            (#"\\(hline|toprule|midrule|bottomrule)\b"#, ""),
            (#"\\cline\{[^}]*\}"#, ""),
            (#"(?<!\\)\$"#, ""),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    public static func looksLikeLatex(_ line: String) -> Bool {
        line.contains("\\") || line.contains("^") || line.contains("_") || line.contains("{")
    }

    static func tokens(in latex: String) -> [Token] {
        var tokens: [Token] = []
        var index = latex.startIndex
        while index < latex.endIndex {
            let character = latex[index]
            if character.isWhitespace {
                index = latex.index(after: index)
                continue
            }
            var end = latex.index(after: index)
            let kind: Token.Kind
            if character == "\\" {
                kind = .command
                if end < latex.endIndex, latex[end].isLetter {
                    while end < latex.endIndex, latex[end].isLetter {
                        end = latex.index(after: end)
                    }
                } else if end < latex.endIndex {
                    end = latex.index(after: end)
                }
            } else if character.isNumber {
                kind = .number
                while end < latex.endIndex, latex[end].isNumber || latex[end] == "." {
                    end = latex.index(after: end)
                }
            } else if character.isLetter {
                kind = .letter
            } else {
                kind = .symbol
            }
            tokens.append(Token(text: String(latex[index..<end]), kind: kind, range: index..<end))
            index = end
        }
        return tokens
    }

    /// Indices of tokens that may be wrapped in a colour group.
    static func wrappableTokenIndices(_ tokens: [Token]) -> Set<Int> {
        var wrappable = Set<Int>()
        var textArgumentDepth: Int?
        var braceDepth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.text == "{" { braceDepth += 1 }
            if token.text == "}" {
                braceDepth -= 1
                if let depth = textArgumentDepth, braceDepth < depth { textArgumentDepth = nil }
            }
            if textArgumentDepth == nil, textArgumentCommands.contains(token.text),
                index + 1 < tokens.count, tokens[index + 1].text == "{"
            {
                textArgumentDepth = braceDepth + 1
            }
            let followsDelimiterCommand =
                index > 0 && ["\\left", "\\right"].contains(tokens[index - 1].text)
            let isWrappable: Bool
            switch token.kind {
            case .command: isWrappable = colourableCommands.contains(token.text)
            case .number, .letter: isWrappable = true
            case .symbol: isWrappable = !syntaxSymbols.contains(token.text)
            }
            if isWrappable, textArgumentDepth == nil, !followsDelimiterCommand,
                !operatorTokens.contains(token.text)
            {
                wrappable.insert(index)
            }
            index += 1
        }
        return wrappable
    }

    /// `line` with the tokens that changed since `previous` wrapped in `{\textcolor{hex}{…}}`.
    public static func highlightingChanges(
        from previous: String?, to line: String, colorHex: String
    )
        -> String
    {
        guard let previous else { return line }
        let oldTexts = tokens(in: previous).map(\.text)
        let newTokens = tokens(in: line)
        let shared = sharedTokenIndices(old: oldTexts, new: newTokens.map(\.text))
        let changedShare = Double(newTokens.count - shared.count) / Double(max(newTokens.count, 1))
        guard changedShare <= largestHighlightedShare else { return line }
        let wrappable = wrappableTokenIndices(newTokens)
        var result = ""
        var cursor = line.startIndex
        for (index, token) in newTokens.enumerated() {
            guard !shared.contains(index), wrappable.contains(index) else { continue }
            result += line[cursor..<token.range.lowerBound]
            // Numbers are coloured digit by digit: SwiftMath asserts ("interelement space
            // undefined for type Number") on a coloured multi-digit number after another atom.
            let pieces = token.kind == .number ? token.text.map(String.init) : [token.text]
            for piece in pieces { result += "{\\textcolor{\(colorHex)}{\(piece)}}" }
            cursor = token.range.upperBound
        }
        result += line[cursor...]
        return result
    }

    /// The left and right of the first `=` outside any braces or `\left…\right`, trimmed.
    public static func splitAtTopLevelEquals(_ latex: String) -> (left: String, right: String)? {
        var depth = 0
        for token in tokens(in: latex) {
            switch token.text {
            // Inside a matrix an "=" is a cell, not the line's equals sign.
            case "{", "\\left", "\\begin": depth += 1
            case "}", "\\right", "\\end": depth -= 1
            case "=" where depth == 0:
                let left = latex[..<token.range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = latex[token.range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { return nil }
                return (left, right)
            default: break
            }
        }
        return nil
    }

    /// New-token indices that are part of the longest common subsequence with the old tokens.
    static func sharedTokenIndices(old: [String], new: [String]) -> Set<Int> {
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for row in stride(from: old.count - 1, through: 0, by: -1) {
            for column in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[row][column] =
                    old[row] == new[column]
                    ? lengths[row + 1][column + 1] + 1
                    : max(lengths[row + 1][column], lengths[row][column + 1])
            }
        }
        var shared = Set<Int>()
        var row = 0
        var column = 0
        while row < old.count, column < new.count {
            if old[row] == new[column] {
                shared.insert(column)
                row += 1
                column += 1
            } else if lengths[row + 1][column] >= lengths[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return shared
    }
}
