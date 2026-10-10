import ChalkCore
import Foundation

// Usage (from the repo root):
//   swift run --package-path Eval/guide-sim GuideSim [--scenario mail-write,flights] [--profile dev]
// Needs Sidecar/dist/tutor-engine. The dev profile's Gemini key comes from the Keychain item
// chalk.dev.gemini-api-key; `--profile demo` uses the Cline sign-in and spends credits (ask first).

@MainActor
func runSimulator() async {
    let arguments = CommandLine.arguments
    func option(_ name: String, _ fallback: String) -> String {
        guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
            return fallback
        }
        return arguments[index + 1]
    }
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let profile = option("profile", "dev")
    let scenarioDirectory = repository.appendingPathComponent("Eval/usecases")
    let wanted = option("scenario", "all")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: scenarioDirectory.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.sorted()
        .filter { wanted == "all" || wanted.split(separator: ",").contains(Substring($0.replacingOccurrences(of: ".json", with: ""))) }
    guard !files.isEmpty else {
        print("no scenarios matched \(wanted) in \(scenarioDirectory.path)")
        return
    }

    var environment = [
        "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "CHALK_MODEL_PROFILE": profile,
    ]
    if profile == "dev" {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        lookup.arguments = ["find-generic-password", "-s", "chalk.dev.gemini-api-key", "-w"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        try? lookup.run()
        lookup.waitUntilExit()
        let key = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            print("no Gemini dev key in the Keychain (chalk.dev.gemini-api-key)")
            return
        }
        environment["GEMINI_API_KEY"] = key
        environment["CLINE_DIR"] = NSTemporaryDirectory() + "chalk-guide-sim"
    } else {
        environment["CLINE_DIR"] = NSHomeDirectory() + "/Library/Application Support/Chalk/cline"
    }
    let engineURL = repository.appendingPathComponent("Sidecar/dist/tutor-engine")
    let client = TutorEngineClient(
        configuration: .init(executableURL: engineURL, environment: environment))
    do { try await client.launch() } catch {
        print("couldn't launch \(engineURL.path): \(error)")
        return
    }
    guard
        let configuration = try? ModelRoutingConfiguration.load(
            from: repository.appendingPathComponent("Sidecar/model-routing.json"))
    else {
        print("couldn't read Sidecar/model-routing.json")
        return
    }
    let models = EngineModels(client: client, router: ModelRouter(configuration: configuration, profileName: profile))

    var reports: [RunReport] = []
    for file in files {
        let url = scenarioDirectory.appendingPathComponent(file)
        let scenario: Scenario
        do {
            scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
        } catch {
            print("✗ \(file): \(error)")
            continue
        }
        print("\n▶︎ \(scenario.name)")
        let harness = SimHarness(scenario: scenario, models: models)
        reports.append(await harness.run())
        try? await Task.sleep(for: .seconds(2))
    }
    await client.shutdown()

    print("free-tier rate-limit waits: \(models.rateLimitWaits) (6 s each, inflate latencies)")
    let markdown = Report.markdown(reports, profile: profile) + "\nRate-limit waits: \(models.rateLimitWaits)\n"
    print("\n" + Report.summaryTable(reports))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    let output = repository.appendingPathComponent(
        "Eval/results/guide-sim-\(profile)-\(formatter.string(from: Date())).md")
    try? markdown.write(to: output, atomically: true, encoding: .utf8)
    print("report: \(output.path)")
}

enum Report {
    static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    static func summaryTable(_ reports: [RunReport]) -> String {
        var lines = [
            "| Scenario | Goal | Finished | Steps shown | Wrong circle | Missing | Stalls | Repeats | Cards | 1st step | Next step p50 / p90 | Calls (planner/scout/checker/fixer) |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        for report in reports {
            func calls(_ role: GuideRole) -> String { String(report.modelCalls[role]?.count ?? 0) }
            let latency =
                "\(percentile(report.stepLatencies, 0.5).map { "\($0)" } ?? "–") / \(percentile(report.stepLatencies, 0.9).map { "\($0)" } ?? "–") ms"
            lines.append(
                "| \(report.scenario) | \(report.reachedGoal ? "✅" : "❌") | \(report.finished ? "✅" : report.timedOut ? "⏰" : "❌") | \(report.presentations) | \(report.wrongPointers) | \(report.missingControls) | \(report.stalls) | \(report.repeats) | \(report.questions.count) | \(report.firstStepMilliseconds.map { "\($0) ms" } ?? "–") | \(latency) | \(calls(.planner))/\(calls(.scout))/\(calls(.checker))/\(calls(.fixer)) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ reports: [RunReport], profile: String) -> String {
        var text = "# Guide simulator run (\(profile) profile)\n\n"
        text += "Scripted screens and a simulated user; real model calls through tutor-engine. "
        text += "Latencies are this profile's models, not Claude's.\n\n"
        text += summaryTable(reports) + "\n\n"
        for report in reports {
            text += "## \(report.scenario)\n\n"
            for (role, entry) in report.modelCalls.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                text += "- \(role.rawValue): \(entry.count) calls, p50 \(percentile(entry.milliseconds, 0.5) ?? 0) ms, \(entry.failures) unusable\n"
            }
            if !report.candidateVerdicts.isEmpty {
                text += "- predictions: \(report.candidateVerdicts.joined(separator: "; "))\n"
            }
            text += "\n```\n" + report.log.joined(separator: "\n") + "\n```\n\n"
        }
        return text
    }
}

await runSimulator()
