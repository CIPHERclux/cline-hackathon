import Foundation

@main
struct VerifyLiveLogs {
    static func main() {
        var buffer = LiveLogBuffer()
        buffer.append(Data("first\nsec".utf8))
        precondition(buffer.lines == ["first"])
        buffer.append(Data("ond\n\n".utf8))
        precondition(buffer.lines == ["first", "second"])
        buffer.clear()
        for index in 0..<(LiveLogBuffer.maximumEntries + 12) {
            buffer.appendLine("event \(index)")
        }
        precondition(buffer.lines.count == LiveLogBuffer.maximumEntries)
        precondition(buffer.lines.first == "event 12")
        buffer.clear()
        for sensitive in [
            "Authorization: Bearer test", "access_token=test", "data:image/png;base64,test",
            "usage 123", "credits 5", "password=test",
        ] {
            buffer.appendLine(sensitive)
        }
        precondition(
            buffer.lines.allSatisfy { $0 == "[diagnostics] Sensitive or accounting event omitted." }
        )
        buffer.clear()
        let unicodeLine = Data("🧭 walkthrough started\n".utf8)
        buffer.append(unicodeLine.prefix(2))
        buffer.append(unicodeLine.dropFirst(2))
        precondition(buffer.lines == ["🧭 walkthrough started"])
        buffer.clear()
        buffer.append(Data(repeating: 65, count: LiveLogBuffer.maximumLineBytes + 1))
        precondition(buffer.lines == ["[diagnostics] Oversized log line omitted."])
        buffer.append(Data("recovered\n".utf8))
        precondition(buffer.lines.last == "recovered")
        print(
            "PASS: fragmented lines, UTF-8, bounded retention, sensitive filtering, clear and oversized input"
        )
    }
}
