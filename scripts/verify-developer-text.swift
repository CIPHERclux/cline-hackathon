import Foundation

@main
struct VerifyDeveloperText {
    static func main() {
        precondition(DeveloperTextRequest.normalized("") == nil)
        precondition(DeveloperTextRequest.normalized(" \n\t ") == nil)
        precondition(
            DeveloperTextRequest.normalized("  Guide me to export this.\n")
                == "Guide me to export this.")
        precondition(DeveloperTextRequest.normalized("second") == "second")
        precondition(DeveloperTextRequest.normalized("stop") == "stop")
        precondition(
            DeveloperTextRequest.normalized("Explain x² + y²\nstep by step")
                == "Explain x² + y²\nstep by step")
        precondition(
            DeveloperTextRequest.normalized(
                String(repeating: "a", count: DeveloperTextRequest.maximumCharacters)) != nil)
        precondition(
            DeveloperTextRequest.normalized(
                String(repeating: "a", count: DeveloperTextRequest.maximumCharacters + 1)) == nil)
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let manager = try! String(
                contentsOf: root.appendingPathComponent("Chalk/CompanionManager.swift"),
                encoding: .utf8)
            let start = manager.range(of: "func submitDeveloperTextRequest")!.lowerBound
            let end = manager.range(
                of: "private func showRegionActionChooser", range: start..<manager.endIndex)!
                .lowerBound
            let requestPath = String(manager[start..<end])
            precondition(requestPath.contains("teachingTurnController.learnerStartedTalking()"))
            precondition(requestPath.contains("teachingTurnController.learnerReleasedKey()"))
            precondition(requestPath.contains("teachingTurnController.ask(request)"))
            precondition(!requestPath.contains("startPushToTalk"))
            precondition(!requestPath.contains("lastTranscript ="))
            precondition(requestPath.contains("chalkDismissPanel"))
            precondition(requestPath.contains("ChalkDeveloperTextInput"))
            print(
                "PASS: text uses capture/ask/audio pipeline, dismisses panel and never starts microphone recording"
            )
        }
        print(
            "PASS: empty/whitespace rejection, trimming, commands, choices, Unicode and request size limit"
        )
    }
}
