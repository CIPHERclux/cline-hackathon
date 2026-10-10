//
//  TutorEngineHost.swift
//  Chalk
//
//  Owns the tutor-engine sidecar for the app (§7.3): finds the bundled binary and routing config,
//  builds its scrubbed environment, launches it at app start (warm-up) and prewarms TLS/auth on
//  the first key press. The process supervision itself lives in ChalkCore's TutorEngineClient.
//

import ChalkCore
import Foundation
import Security
import os

@MainActor
final class TutorEngineHost {
    private static let log = Logger(subsystem: "com.chalk.app", category: "engine")
    /// Which `model-routing.json` profile to use: "demo" (Cline credits) or "dev" (free Gemini,
    /// D37). Persisted; the panel's profile switch changes it.
    static let modelProfileDefaultsKey = "ChalkModelProfile"
    static let geminiKeychainService = "chalk.dev.gemini-api-key"

    private(set) var client: TutorEngineClient?
    private(set) var router: ModelRouter?
    private(set) var profileName: String
    private var hasPrewarmedThisLaunch = false

    init() {
        profileName = UserDefaults.standard.string(forKey: Self.modelProfileDefaultsKey) ?? "demo"
    }

    /// §7.3 Location: `Chalk.app/Contents/Helpers/tutor-engine`, copied in by the build.
    static var bundledEngineURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tutor-engine")
    }

    /// §7.3 Launch: sessions and the Cline sign-in live here (owner-only files, D39).
    static var clineDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chalk/cline", isDirectory: true)
    }

    /// Bumped each time a new engine process starts (launch, profile switch): its sessions
    /// don't exist in the next one, so a follow-up must not continue them.
    private(set) var engineGeneration = 0

    func start() async {
        engineGeneration += 1
        do {
            guard
                let routingURL = Bundle.main.url(
                    forResource: "model-routing", withExtension: "json")
            else {
                Self.log.error("Engine startup failed: routing configuration missing from bundle")
                print("⚠️ TutorEngine: model-routing.json is missing from the app bundle")
                return
            }
            router = ModelRouter(
                configuration: try ModelRoutingConfiguration.load(from: routingURL),
                profileName: profileName)
            guard FileManager.default.isExecutableFile(atPath: Self.bundledEngineURL.path) else {
                Self.log.error(
                    "Engine startup failed: bundled helper missing or not executable; rebuild Sidecar"
                )
                print(
                    "⚠️ TutorEngine: no engine at \(Self.bundledEngineURL.path). Run `cd Sidecar && bun run build:bin`, then rebuild the app."
                )
                return
            }
            let client = TutorEngineClient(
                configuration: .init(
                    executableURL: Self.bundledEngineURL, environment: engineEnvironment()))
            try await client.launch()
            self.client = client
            Self.log.notice(
                "Engine started: profile=\(self.profileName, privacy: .public) generation=\(self.engineGeneration)"
            )
            print("🧠 TutorEngine: running (profile \(profileName))")
            Task { [notices = client.notices] in
                for await notice in notices {
                    Self.log.notice(
                        "Engine lifecycle: \(String(describing: notice), privacy: .public)")
                    print("🧠 TutorEngine: \(notice)")
                }
            }
        } catch {
            Self.log.error("Engine launch failed (details in Xcode console)")
            print("⚠️ TutorEngine: failed to start: \(error)")
        }
    }

    func stop() async {
        Self.log.notice("Engine shutdown requested")
        await client?.shutdown()
        client = nil
    }

    /// Switches between the Cline (`demo`) and free Gemini (`dev`) profiles by restarting the engine.
    func switchProfile(to newProfileName: String) async {
        guard newProfileName != profileName else { return }
        Self.log.notice("Engine profile switch: \(newProfileName, privacy: .public)")
        UserDefaults.standard.set(newProfileName, forKey: Self.modelProfileDefaultsKey)
        profileName = newProfileName
        hasPrewarmedThisLaunch = false
        await stop()
        await start()
    }

    /// §7.3 Warm-up: the first key press opens TLS and auth while the learner is still talking.
    func prewarmIfNeeded() {
        guard !hasPrewarmedThisLaunch, let client else { return }
        hasPrewarmedThisLaunch = true
        Task { _ = await client.prewarm(slot: ModelSlot.teaching.rawValue) }
    }

    /// §7.3 Launch: "the environment is otherwise scrubbed": no inherited secrets or proxies.
    private func engineEnvironment() -> [String: String] {
        try? FileManager.default.createDirectory(
            at: Self.clineDirectoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "CLINE_DIR": Self.clineDirectoryURL.path,
            "CHALK_MODEL_PROFILE": profileName,
        ]
        if profileName == "dev" {
            if let geminiKey = Self.readGeminiKeyFromKeychain() {
                environment["GEMINI_API_KEY"] = geminiKey
            } else {
                print(
                    "⚠️ TutorEngine: dev profile needs the Keychain item \(Self.geminiKeychainService)"
                )
            }
        }
        return environment
    }

    /// The owner's dev-only Gemini key (D37), stored with
    /// `security add-generic-password -s chalk.dev.gemini-api-key`. Never written to a file.
    /// Read through `/usr/bin/security`, the tool that created the item and that its access list
    /// trusts. Reading it directly made macOS ask for the password after every build: each
    /// ad-hoc build is a new app to the Keychain (owner's report).
    private static func readGeminiKeyFromKeychain() -> String? {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        lookup.arguments = ["find-generic-password", "-s", geminiKeychainService, "-w"]
        let output = Pipe()
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        do { try lookup.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        guard lookup.terminationStatus == 0 else { return nil }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }
}
