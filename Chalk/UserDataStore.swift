//
//  UserDataStore.swift
//  Chalk
//
//  What Chalk keeps on this Mac between launches (§4.3, §10.1): user memory, saved how-tos and
//  the study/kids mode switches. JSON files in Application Support/Chalk, owner-only; nothing
//  leaves the Mac except the short memory summary sent with a question (§10.1). The demo uses
//  files rather than SwiftData (§7.7): two small documents, read once at launch.
//

import ChalkCore
import Combine
import Foundation

/// A finished walkthrough kept so it can be run again (§4.3 "Saved how-tos").
struct SavedHowTo: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var appName: String?
    var createdAt: Date
    var lastRunAt: Date
    var steps: [WalkthroughStep]

    var recapText: String {
        WalkthroughSession.recapText(title: title, appName: appName, steps: steps)
    }
}

@MainActor
final class UserDataStore: ObservableObject {
    static let maximumSavedHowToCount = 50
    static let studyModeDefaultsKey = "ChalkStudyMode"
    static let kidsModeDefaultsKey = "ChalkKidsMode"

    @Published private(set) var memory: UserMemory
    @Published private(set) var savedHowTos: [SavedHowTo]
    @Published private(set) var modes: AssistantModes

    private let directoryURL: URL
    private var memoryURL: URL { directoryURL.appendingPathComponent("memory.json") }
    private var howTosURL: URL { directoryURL.appendingPathComponent("howtos.json") }

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chalk", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
        memory =
            Self.load(UserMemory.self, from: directoryURL.appendingPathComponent("memory.json"))
            ?? UserMemory()
        savedHowTos =
            Self.load([SavedHowTo].self, from: directoryURL.appendingPathComponent("howtos.json"))
            ?? []
        modes = AssistantModes(
            isStudyModeOn: UserDefaults.standard.bool(forKey: Self.studyModeDefaultsKey),
            isKidsModeOn: UserDefaults.standard.bool(forKey: Self.kidsModeDefaultsKey))
    }

    // MARK: - Modes

    func setStudyMode(_ isOn: Bool) {
        modes.isStudyModeOn = isOn
        UserDefaults.standard.set(isOn, forKey: Self.studyModeDefaultsKey)
    }

    func setKidsMode(_ isOn: Bool) {
        modes.isKidsModeOn = isOn
        UserDefaults.standard.set(isOn, forKey: Self.kidsModeDefaultsKey)
    }

    // MARK: - Memory

    func apply(_ rememberAction: RememberAction) {
        memory.apply(rememberAction, at: Date())
        print("🧠 Memory: remembered \"\(rememberAction.fact)\"")
        saveMemory()
    }

    func addFact(_ fact: String) {
        guard memory.remember(fact) else { return }
        saveMemory()
    }

    func forgetFact(at index: Int) {
        memory.forget(factAt: index)
        saveMemory()
    }

    func setSkill(_ skill: UserMemory.SkillLevel?, forApp appName: String) {
        memory.setSkill(skill, forApp: appName, at: Date())
        saveMemory()
    }

    func forgetApp(_ appName: String) {
        memory.apps.removeValue(forKey: appName)
        saveMemory()
    }

    func clearMemory() {
        memory = UserMemory()
        saveMemory()
    }

    func recordQuestion(inApp appName: String?) {
        guard let appName else { return }
        memory.recordQuestion(inApp: appName, at: Date())
        saveMemory()
    }

    func recordWalkthroughCompleted(inApp appName: String?) {
        guard let appName else { return }
        memory.recordWalkthroughCompleted(inApp: appName, at: Date())
        saveMemory()
    }

    // MARK: - Saved how-tos

    /// Saves a finished walkthrough; running a saved one again only refreshes its date.
    func saveHowTo(title: String, appName: String?, steps: [WalkthroughStep], replacing id: UUID?) {
        guard !steps.isEmpty else { return }
        let now = Date()
        if let id, let index = savedHowTos.firstIndex(where: { $0.id == id }) {
            savedHowTos[index].lastRunAt = now
        } else {
            savedHowTos.insert(
                SavedHowTo(
                    id: UUID(), title: title, appName: appName, createdAt: now, lastRunAt: now,
                    steps: steps), at: 0)
            if savedHowTos.count > Self.maximumSavedHowToCount {
                savedHowTos.removeLast(savedHowTos.count - Self.maximumSavedHowToCount)
            }
        }
        saveHowTos()
    }

    func deleteHowTo(_ id: UUID) {
        savedHowTos.removeAll { $0.id == id }
        saveHowTos()
    }

    // MARK: - Files

    private func saveMemory() { Self.save(memory, to: memoryURL, directoryURL: directoryURL) }
    private func saveHowTos() { Self.save(savedHowTos, to: howTosURL, directoryURL: directoryURL) }

    private static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            print("⚠️ UserData: couldn't read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func save<Value: Encodable>(_ value: Value, to url: URL, directoryURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("⚠️ UserData: couldn't save \(url.lastPathComponent): \(error)")
        }
    }
}
