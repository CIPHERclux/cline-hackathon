import Foundation

/// Bounded, session-only diagnostics; never stores screenshots or writes a log file (§10.1).
struct LiveLogBuffer {
    static let maximumEntries = 1000
    static let maximumLineBytes = 8192
    private(set) var lines: [String] = []
    private var pending = Data()

    mutating func append(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let lineBytes = pending.prefix(upTo: newline)
            let line =
                lineBytes.count > Self.maximumLineBytes
                ? "[diagnostics] Oversized log line omitted."
                : String(decoding: lineBytes, as: UTF8.self)
            pending.removeSubrange(...newline)
            appendLine(line)
        }
        if pending.count > Self.maximumLineBytes {
            pending.removeAll(keepingCapacity: true)
            appendLine("[diagnostics] Oversized log line omitted.")
        }
    }

    mutating func appendLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Never surface credential material, image payloads or usage accounting (§3.8, D66).
        let blocked = [
            "access_token", "refresh_token", "authorization:", "bearer ", "api_key",
            "apikey", "data:image", "inputtokens", "outputtokens", "costindollars",
            "credits", "tokens", "usage", "cost", "password", "secret",
        ]
        let normalized = trimmed.lowercased()
        let safeLine =
            blocked.contains(where: normalized.contains)
            ? "[diagnostics] Sensitive or accounting event omitted."
            : String(trimmed.prefix(Self.maximumLineBytes))
        lines.append(safeLine)
        if lines.count > Self.maximumEntries {
            lines.removeFirst(lines.count - Self.maximumEntries)
        }
    }

    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }
}
