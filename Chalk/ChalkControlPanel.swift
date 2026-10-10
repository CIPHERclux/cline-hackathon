//
//  ChalkControlPanel.swift
//  Chalk
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and workspace settings. Editorial paper
//  cards and a plum masthead distinguish the presentation from the screen overlay.
//

import AVFoundation
import SwiftUI

struct ChalkControlPanel: View {
    @ObservedObject var companionManager: CompanionManager
    let onOpenLiveLogs: () -> Void
    let onSubmitDeveloperText: (String) -> Bool
    @State private var emailInput: String = ""
    @AppStorage("ChalkDeveloperTextInput") private var developerTextInputEnabled = false
    @State private var developerRequest = ""
    @State private var developerRequestError: String?

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroSection
                    developerTextInputSection
                    Button(action: onOpenLiveLogs) {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.path.ecg.rectangle")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Live Logs").font(.system(size: 13, weight: .semibold))
                                Text("Watch turns, drawings, walkthroughs and errors")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .foregroundStyle(DS.Colors.textPrimary)
                        .chalkCard()
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    if companionManager.hasCompletedOnboarding
                        && companionManager.allPermissionsGranted
                    {
                        VStack(alignment: .leading, spacing: 10) {
                            ChalkSectionLabel(title: "Your workspace")
                            modelPickerRow
                            presenterModeRow
                        }
                        .chalkCard()
                        WorkspacePreferencesView(
                            userData: companionManager.userDataStore,
                            onRunHowTo: { companionManager.runSavedHowTo($0) })
                        #if DEBUG
                            DisclosureGroup("Developer studio") {
                                localDrawingTestRow
                                localScriptTestRow(
                                    "Math steps", TeachingTurnController.localMathStepsTestScript)
                                localScriptTestRow(
                                    "Number line", TeachingTurnController.localNumberLineTestScript)
                                localScriptTestRow(
                                    "Geometry", TeachingTurnController.localGeometryTestScript)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .tint(DS.Colors.accent)
                            .chalkCard()
                        #endif
                    }
                    if !companionManager.allPermissionsGranted {
                        VStack(alignment: .leading, spacing: 10) {
                            ChalkSectionLabel(title: "Connect your workspace")
                            settingsSection
                        }
                        .chalkCard()
                    }
                    if !companionManager.hasCompletedOnboarding
                        && companionManager.allPermissionsGranted
                    {
                        startButton.chalkCard()
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "hand.raised")
                        Text("Screen capture only when you ask for help.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .frame(maxHeight: 540)
            footerSection
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(DS.Colors.surface2)
        }
        .frame(width: 400)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            ChalkBrandMark(size: 34)
            Text("chalk")
                .font(.system(size: 25, weight: .semibold, design: .serif))
                .tracking(-1)
                .foregroundStyle(DS.Colors.paper)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusDotColor).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(DS.Colors.paper.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.08), in: Capsule())
            Button {
                NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.paper.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close panel")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(DS.Colors.ink)
    }

    private var developerTextInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    ChalkSectionLabel(title: "Developer options")
                    Text("Text input · spoken responses")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                Toggle("Developer text input", isOn: $developerTextInputEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .pointerCursor()
            }
            if developerTextInputEnabled {
                TextField(
                    "Ask about your screen or type a walkthrough request…", text: $developerRequest
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(12)
                .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { submitDeveloperRequest() }
                .accessibilityLabel("Developer text request")
                HStack {
                    Text("Enter to send · audio and drawings stay on")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button(action: submitDeveloperRequest) {
                        Label("Send", systemImage: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Colors.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(DS.Colors.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(DeveloperTextRequest.normalized(developerRequest) == nil)
                }
                Text(
                    "The panel closes before capture. Existing setup permissions are required; no microphone recording is started. Works with adaptive guidance, follow-ups, choices and commands."
                )
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                if developerRequest.count > DeveloperTextRequest.maximumCharacters {
                    Text(
                        "Keep requests under \(DeveloperTextRequest.maximumCharacters) characters."
                    )
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.destructiveText)
                }
                if let developerRequestError {
                    Text(developerRequestError).font(.system(size: 11))
                        .foregroundStyle(DS.Colors.destructiveText)
                }
            }
        }
        .chalkCard()
        .onChange(of: developerTextInputEnabled) { _, enabled in
            if !enabled {
                developerRequest = ""
                developerRequestError = nil
            }
        }
    }

    private func submitDeveloperRequest() {
        guard developerTextInputEnabled,
            let request = DeveloperTextRequest.normalized(developerRequest)
        else { return }
        if onSubmitDeveloperText(request) {
            developerRequest = ""
            developerRequestError = nil
        } else {
            developerRequestError =
                "Complete setup and wait until microphone recording or the introduction has finished, then retry."
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChalkSectionLabel(
                title: companionManager.hasCompletedOnboarding
                    ? "A little clarity, on demand" : "Make yourself at home")
            Text(
                companionManager.hasCompletedOnboarding
                    ? "Your screen.\nA fresh perspective." : "Meet your\nscreen-side guide."
            )
            .font(.system(size: 32, weight: .regular, design: .serif))
            .tracking(-1.1)
            .foregroundStyle(DS.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            permissionsCopySection
            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                HStack(spacing: 8) {
                    keycap("⌃")
                    keycap("⌥")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to talk")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Ask, point, or draw a region")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 22))
                        .foregroundStyle(DS.Colors.accent)
                }
                .padding(14)
                .background(DS.Colors.accentSubtle, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(DS.Colors.ink)
            .frame(width: 38, height: 40)
            .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Ask about anything on screen. Get an answer, a pointer, or a step-by-step guide.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("One last detail before we begin.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Add your email to complete setup.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("Everything is connected. Let’s take a quick tour.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Chalk.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clarity, right where you need it.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(
                    "Talk through a question. Follow a walkthrough. Draw around something you want to understand."
                )
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Connect the permissions below to enable voice and on-screen guidance. You stay in control of every capture."
                )
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(
                                cornerRadius: DS.CornerRadius.medium, style: .continuous
                            )
                            .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: DS.CornerRadius.medium, style: .continuous
                            )
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: DS.CornerRadius.large, style: .continuous
                                )
                                .fill(
                                    emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                                        ? DS.Colors.accent.opacity(0.4)
                                        : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Take the tour")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: DS.CornerRadius.large, style: .continuous
                            )
                            .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(
                        isGranted
                            ? "Only takes a screenshot when you use the hotkey"
                            : "Quit and reopen after granting"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Show Chalk Cursor Toggle

    private var showChalkCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Chalk")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { companionManager.isChalkCursorEnabled },
                    set: { companionManager.setChalkCursorEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            // The router picks the model per question (§7.4); this only picks whose credits
            // answer: Cline (demo) or free Gemini while developing (D37).
            Text("Models")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Cline", profile: "demo")
                modelOptionButton(label: "Gemini (dev)", profile: "dev")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    /// §6.6 Presenter mode (D53): off keeps drawings out of other apps' captures.
    private var presenterModeRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show drawings in recordings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("For screen shares and demo videos")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { companionManager.isPresenterModeOn },
                    set: { companionManager.setPresenterMode($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, profile: String) -> some View {
        let isSelected = companionManager.modelProfile == profile
        return Button(action: {
            companionManager.setModelProfile(profile)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? DS.Colors.paper : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    #if DEBUG
        /// S4 sync check (§11.2): draws a fixed local script, no model, no credits.
        private var localDrawingTestRow: some View {
            Button(action: {
                NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
                companionManager.teachingTurnController.runLocalDrawingTest()
            }) {
                Text("Test drawing (S4)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    #endif

    #if DEBUG
        /// A fixed local script, no model, no credits.
        private func localScriptTestRow(_ title: String, _ script: [String]) -> some View {
            Button(action: {
                NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
                companionManager.teachingTurnController.runLocalScript(script)
            }) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    #endif

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Chalk")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Replay introduction")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.apricot
        case .processing, .responding:
            return DS.Colors.apricot
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
