import Foundation

/// Text matching that tolerates OCR (§6.2 "text anchor: fuzzy OCR match"): ranks a candidate line
/// against the text the model named. Lower is better: 0 exact, 1 prefix, 2 contains, 3 a close
/// misread ("Aut0 1ayout" for "Auto layout"); nil is no match.
public enum FuzzyTextMatch {
    /// Edit-distance similarity a misread must reach; only for words of 4+ characters, so short
    /// labels ("OK", "on") never match each other.
    static let misreadSimilarity = 0.8
    static let minimumLengthForMisreads = 4

    public static func rank(candidate: String, wanted: String) -> Int? {
        let candidateText = normalized(candidate)
        let wantedText = normalized(wanted)
        guard !candidateText.isEmpty, !wantedText.isEmpty else { return nil }
        if candidateText == wantedText { return 0 }
        if candidateText.hasPrefix(wantedText)
            || wantedText.hasPrefix(candidateText) && candidateText.count >= 3
        {
            return 1
        }
        if candidateText.contains(wantedText) { return 2 }
        if wantedText.count >= minimumLengthForMisreads,
            similarity(candidateText, wantedText) >= misreadSimilarity
        {
            return 3
        }
        return nil
    }

    /// 1 − Levenshtein distance / longer length.
    public static func similarity(_ first: String, _ second: String) -> Double {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        let longerLength = max(firstCharacters.count, secondCharacters.count)
        guard longerLength > 0 else { return 1 }
        var previousRow = Array(0...secondCharacters.count)
        for (firstIndex, firstCharacter) in firstCharacters.enumerated() {
            var currentRow = [firstIndex + 1]
            for (secondIndex, secondCharacter) in secondCharacters.enumerated() {
                let substitution =
                    previousRow[secondIndex] + (firstCharacter == secondCharacter ? 0 : 1)
                currentRow.append(
                    min(substitution, previousRow[secondIndex + 1] + 1, currentRow[secondIndex] + 1)
                )
            }
            previousRow = currentRow
        }
        return 1 - Double(previousRow[secondCharacters.count]) / Double(longerLength)
    }

    /// Lowercased letters and digits separated by single spaces ("Set up billing…" → "set up billing").
    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}
