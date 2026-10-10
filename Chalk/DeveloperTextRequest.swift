import Foundation

/// Explicit developer requests use the normal turn path without microphone capture (§7.6, D83).
enum DeveloperTextRequest {
    static let maximumCharacters = 4000

    static func normalized(_ text: String) -> String? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, request.count <= maximumCharacters else { return nil }
        return request
    }
}
