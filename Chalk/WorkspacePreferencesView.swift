//
//  WorkspacePreferencesView.swift
//  Chalk
//
//  The panel's §4.3 controls: study and kids modes, saved how-tos (run again, copy, delete)
//  and the user memory Chalk keeps (inspect, add, forget, set skill per app). Observes the
//  UserDataStore so edits show at once.
//

import AppKit
import ChalkCore
import SwiftUI

struct WorkspacePreferencesView: View {
    @ObservedObject var userData: UserDataStore
    let onRunHowTo: (SavedHowTo) -> Void

    @State private var isMemoryExpanded = false
    @State private var isHowTosExpanded = true
    @State private var newFactText = ""
    @State private var copiedHowToIdentifier: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChalkSectionLabel(title: "Make it yours")
            Text("Rolling guidance · one planner, locally verified steps")
                .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            modeRow(
                title: "Study mode", subtitle: "Hints first, no finished homework answers",
                isOn: Binding(
                    get: { userData.modes.isStudyModeOn }, set: { userData.setStudyMode($0) }))
            modeRow(
                title: "Kids mode", subtitle: "Simpler words, slower voice, safer answers",
                isOn: Binding(
                    get: { userData.modes.isKidsModeOn }, set: { userData.setKidsMode($0) }))
            howTosSection
            memorySection
        }
        .chalkCard()
    }

    // MARK: - Modes

    private func modeRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Saved how-tos

    private var howTosSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(
                "SAVED HOW-TOS", count: userData.savedHowTos.count, isExpanded: $isHowTosExpanded)
            if isHowTosExpanded {
                if userData.savedHowTos.isEmpty {
                    Text("Say \"guide me how to…\" to build your personal playbook.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(userData.savedHowTos.prefix(6)) { howTo in
                        howToRow(howTo)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func howToRow(_ howTo: SavedHowTo) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(howTo.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(
                    "\(howTo.appName.map { "\($0) · " } ?? "")\(howTo.steps.count) steps"
                )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 4)
            smallButton("Run") { onRunHowTo(howTo) }
            smallButton(copiedHowToIdentifier == howTo.id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(howTo.recapText, forType: .string)
                copiedHowToIdentifier = howTo.id
            }
            iconButton("trash") { userData.deleteHowTo(howTo.id) }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(
                "MEMORY", count: userData.memory.facts.count + userData.memory.apps.count,
                isExpanded: $isMemoryExpanded)
            if isMemoryExpanded {
                Text("Kept on this Mac. A short summary goes with each question.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                ForEach(Array(userData.memory.facts.enumerated()), id: \.offset) { index, fact in
                    HStack(spacing: 6) {
                        Text(fact)
                            .font(.system(size: 11.5))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        iconButton("xmark") { userData.forgetFact(at: index) }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Add something Chalk should know", text: $newFactText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .onSubmit(addFact)
                    smallButton("Add", action: addFact)
                }
                if !userData.memory.apps.isEmpty {
                    Text("APPS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 4)
                    ForEach(
                        userData.memory.apps.sorted { $0.value.lastUsed > $1.value.lastUsed }
                            .prefix(8),
                        id: \.key
                    ) { appName, record in
                        appRow(appName: appName, record: record)
                    }
                }
                if !userData.memory.isEmpty {
                    Button(action: { userData.clearMemory() }) {
                        Text("Forget everything")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.destructiveText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.top, 2)
                }
            }
        }
        .padding(.top, 8)
    }

    private func appRow(appName: String, record: UserMemory.AppRecord) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(
                    "\(record.questionCount) questions · \(record.walkthroughsCompleted) walkthroughs"
                )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Not set") { userData.setSkill(nil, forApp: appName) }
                ForEach(UserMemory.SkillLevel.allCases, id: \.self) { level in
                    Button(level.rawValue.capitalized) { userData.setSkill(level, forApp: appName) }
                }
            } label: {
                Text(record.skill?.rawValue.capitalized ?? "Skill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointerCursor()
            iconButton("xmark") { userData.forgetApp(appName) }
        }
    }

    private func addFact() {
        let fact = newFactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        userData.addFact(fact)
        newFactText = ""
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, count: Int, isExpanded: Binding<Bool>) -> some View
    {
        Button(action: { isExpanded.wrappedValue.toggle() }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(4)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
