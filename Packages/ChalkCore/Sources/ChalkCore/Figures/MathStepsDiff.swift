import Foundation

/// Which parts of a math step changed from the line before (§4.2.3 "highlighted diffs"):
/// a token-level longest-common-subsequence diff, so `x = 0.999…` → `10x = 9.999…` highlights
/// "10" and "9.999…". Pure; the whiteboard colours the returned ranges.
public enum MathStepsDiff {
    public struct Token: Equatable, Sendable {
        public var text: String
        public var range: Range<String.Index>
    }

    /// Numbers (digits with `.`, `,` and `…`), runs of letters, and single symbols; spaces split.
    public static func tokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        func isNumberCharacter(_ character: Character) -> Bool {
            character.isNumber || character == "." || character == "," || character == "…"
        }
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace {
                index = line.index(after: index)
                continue
            }
            var end = line.index(after: index)
            if character.isNumber {
                while end < line.endIndex, isNumberCharacter(line[end]) {
                    end = line.index(after: end)
                }
            } else if character.isLetter {
                while end < line.endIndex, line[end].isLetter { end = line.index(after: end) }
            }
            tokens.append(Token(text: String(line[index..<end]), range: index..<end))
            index = end
        }
        return tokens
    }

    /// Ranges of `line` not shared with `previous`; touching ranges (only spaces between) merge.
    public static func changedRanges(from previous: String?, to line: String) -> [Range<
        String.Index
    >] {
        guard let previous else { return [] }
        let oldTokens = tokens(in: previous).map(\.text)
        let newTokens = tokens(in: line)
        // LCS table over token texts.
        let rows = oldTokens.count
        let columns = newTokens.count
        var lengths = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                lengths[row][column] =
                    oldTokens[row] == newTokens[column].text
                    ? lengths[row + 1][column + 1] + 1
                    : max(lengths[row + 1][column], lengths[row][column + 1])
            }
        }
        var isShared = Array(repeating: false, count: columns)
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if oldTokens[row] == newTokens[column].text {
                isShared[column] = true
                row += 1
                column += 1
            } else if lengths[row + 1][column] >= lengths[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        var ranges: [Range<String.Index>] = []
        for (tokenIndex, token) in newTokens.enumerated() where !isShared[tokenIndex] {
            if let last = ranges.last,
                line[last.upperBound..<token.range.lowerBound].allSatisfy(\.isWhitespace),
                tokenIndex > 0, !isShared[tokenIndex - 1]
            {
                ranges[ranges.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                ranges.append(token.range)
            }
        }
        return ranges
    }
}
