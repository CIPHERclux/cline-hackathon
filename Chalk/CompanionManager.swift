//
//  CompanionManager.swift
//  Chalk
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import ChalkCore
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by ChalkCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so ChalkCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// ChalkCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// True while the annotation pen (D50) is out: the buddy hides, because the pen is the
    /// buddy flying off to draw.
    @Published private(set) var isAnnotationPenActive = false

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = ScreenBeaconOverlayManager()
    /// §4.2.5: takes the mouse on the active display only while ⌃⌥ is held.
    private let drawChordPanel = DrawChordPanel()
    /// A lasso was released without speech so far; if no transcript arrives, the chooser offers
    /// Explain / Summarise / Translate (§4.2.5, §4.3).
    private var isWaitingToExplainLearnerRegion = false
    private let regionActionChooser = RegionActionChooser()
    /// A transcript arrived for the current key press (an empty press re-shows a walkthrough
    /// step, §4.2.6).
    private var receivedTranscriptSinceKeyDown = false
    /// Memory, saved how-tos and the study/kids modes (§4.3), on this Mac only.
    let userDataStore = UserDataStore()
    /// The Cline sidecar (§7.3) and the per-turn voice loop (§7.6). All reasoning goes through
    /// tutor-engine; there is no direct model API and no proxy Worker any more (D13).
    let tutorEngineHost = TutorEngineHost()
    private(set) lazy var teachingTurnController: TeachingTurnController = {
        let controller = TeachingTurnController(engineHost: tutorEngineHost, userData: userDataStore)
        controller.onStateChange = { [weak self] turnState in
            self?.handleTeachingTurnStateChange(turnState)
        }
        controller.voiceOut.onCaptionUpdate = { [weak self] spokenText, currentWordRange in
            self?.showCaption(spokenText, currentWordRange: currentWordRange)
        }
        controller.annotationController.onPenActiveChanged = { [weak self] isActive in
            self?.isAnnotationPenActive = isActive
        }
        return controller
    }()

    // MARK: - Captions (§5.1 HUD, §5.4: "Speaking: captions highlight the current word")

    /// The sentence Chalk is saying, shown next to the cursor so the answer can be read too.
    @Published private(set) var captionText: String = ""
    /// How long a caption stays readable after Chalk stops talking.
    private static let captionLingerSeconds: Double = 2.5
    private var captionClearTask: Task<Void, Never>?

    /// Captions are off by default (owner, 2026-10-03, D46). Turn them on with
    /// `defaults write com.yourcompany.leanring-buddy ChalkShowsCaptions -bool true`.
    static let showsCaptionsDefaultsKey = "ChalkShowsCaptions"

    private func showCaption(_ spokenText: String, currentWordRange: NSRange) {
        guard UserDefaults.standard.bool(forKey: Self.showsCaptionsDefaultsKey) else { return }
        captionClearTask?.cancel()
        captionClearTask = nil
        captionText = spokenText
    }

    private func clearCaption(afterSeconds delaySeconds: Double) {
        captionClearTask?.cancel()
        guard delaySeconds > 0 else {
            captionText = ""
            return
        }
        captionClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self, !Task.isCancelled else { return }
            self.captionText = ""
        }
    }

    private var shortcutTransitionCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var screenshotChordCancellable: AnyCancellable?
    /// Restores the overlays after a screenshot chord: one work item, only after a chord.
    private var screenshotHideRestoreWorkItem: DispatchWorkItem?
    private var screenParametersObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    /// The display layout overlays were built for; the notification also fires for Dock and
    /// menu-bar changes, which must not wipe marks.
    private var lastDisplayLayout: [[CGFloat]] = []
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the Chalk beacon overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Which model profile answers: "demo" (Cline credits) or "dev" (free Gemini until the
    /// hackathon, D37). Models within a profile are picked per turn by the router (§7.4).
    @Published private(set) var modelProfile: String =
        UserDefaults.standard.string(forKey: TutorEngineHost.modelProfileDefaultsKey) ?? "demo"

    /// Presenter mode (§6.6, D53): drawings show up in screen shares and recordings. Off by
    /// default (§16 open question 14); turn it on to record or screen-share a demo.
    @Published private(set) var isPresenterModeOn = UserDefaults.standard.bool(
        forKey: ChalkOverlaySharing.presenterModeDefaultsKey)

    func setPresenterMode(_ isOn: Bool) {
        isPresenterModeOn = isOn
        UserDefaults.standard.set(isOn, forKey: ChalkOverlaySharing.presenterModeDefaultsKey)
        overlayWindowManager.applySharingType()
        teachingTurnController.annotationController.applySharingType()
    }

    func setModelProfile(_ profile: String) {
        guard profile != modelProfile else { return }
        modelProfile = profile
        Task { await tutorEngineHost.switchProfile(to: profile) }
    }

    /// User preference for whether the Chalk cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isChalkCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setChalkCursorEnabled(_ enabled: Bool) {
        isChalkCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Onboarding's email step. Nothing leaves the Mac any more: the FormSpark submission and
    /// the PostHog identify are gone (D14, §10.1). The onboarding itself is replaced in S13 (D15).
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Chalk start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindNothingRecognizedFeedback()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        observeDisplayAndSpaceChanges()
        // §7.3 Warm-up: launch the sidecar now; the first key press prewarms TLS and auth.
        Task { await tutorEngineHost.start() }
        // §7.6: install the on-device speech model before the first question needs it.
        Task { await SpeechService.prepareSpeechAssetsIfNeeded() }
        // Vision's first accurate OCR loads its model (~24 s cold): do it now, not on the first question.
        PerceptionService.warmUpInBackground()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isChalkCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by ChalkCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ChalkAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
        ChalkAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Chalk: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Chalk: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        pendingDeveloperTextRequestTask?.cancel()
        pendingDeveloperTextRequestTask = nil
        teachingTurnController.walkthroughController.end(saying: nil)
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        teachingTurnController.voiceOut.stop()
        Task { await tutorEngineHost.stop() }
        shortcutTransitionCancellable?.cancel()
        escapeKeyCancellable?.cancel()
        screenshotChordCancellable?.cancel()
        screenshotHideRestoreWorkItem?.cancel()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ChalkAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ChalkAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ChalkAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ChalkAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ChalkAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isChalkCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    /// P-IDLECPU (§6.5): polling stops once everything is granted; opening the panel checks again
    /// and restarts it if something was revoked.
    func startPermissionPolling() {
        guard accessibilityCheckTimer == nil else { return }
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAllPermissions()
                if self.allPermissionsGranted {
                    self.accessibilityCheckTimer?.invalidate()
                    self.accessibilityCheckTimer = nil
                }
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    /// Never silent when a held press got no words (owner's log): say whether the mic sent no
    /// sound at all, or sound that wasn't understood. At most once a minute for the mic.
    private var lastMicrophoneWarningAt = Date.distantPast

    private func bindNothingRecognizedFeedback() {
        buddyDictationManager.onNothingRecognized = { [weak self] heardSound in
            guard let self, !self.isWaitingToExplainLearnerRegion else { return }
            let voiceOut = self.teachingTurnController.voiceOut
            if heardSound {
                voiceOut.speak(SpeakAction(text: "Sorry, I didn't catch that."))
            } else if Date().timeIntervalSince(self.lastMicrophoneWarningAt) > 60 {
                self.lastMicrophoneWarningAt = Date()
                voiceOut.speak(
                    SpeakAction(
                        text:
                            "I can't hear your microphone. Check the input in Sound settings, then try again."
                    ))
            }
        }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // §4.2.5: lasso + release without speech offers Explain / Summarise /
                    // Translate. The transcript can land just after this idle state, so wait a
                    // moment and offer only if no spoken question started a turn: firing at once
                    // ran two answers together (owner's report, D65).
                    if self.isWaitingToExplainLearnerRegion {
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(1.5))
                            guard let self, self.isWaitingToExplainLearnerRegion,
                                !self.teachingTurnController.isBusy
                            else { return }
                            self.isWaitingToExplainLearnerRegion = false
                            self.showRegionActionChooser()
                        }
                        return
                    }
                    // §4.2.6: the key was pressed during a walkthrough but nothing was said;
                    // the step's marks were cleared by the press, so show it again.
                    if self.teachingTurnController.walkthroughController.isActive,
                        !self.receivedTranscriptSinceKeyDown
                    {
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(1.5))
                            guard let self, !self.receivedTranscriptSinceKeyDown,
                                !self.teachingTurnController.isBusy,
                                !self.buddyDictationManager.isDictationInProgress
                            else { return }
                            self.teachingTurnController.walkthroughController
                                .userFinishedTalkingWithoutSpeech()
                        }
                    }
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if !self.teachingTurnController.isBusy {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKey()
            }
        screenshotChordCancellable = globalPushToTalkShortcutMonitor
            .screenshotChordPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.hideOverlaysForScreenshot()
            }
    }

    /// §6.6 / P-SCRNSHOT: on ⇧⌘3/4/5 every overlay hides for 10 s (another chord restarts the
    /// count), so the screenshot UI and tools that ignore `sharingType` see a clean screen.
    private func hideOverlaysForScreenshot() {
        // Presenter mode wants the drawings in captures (D53); the owner's test showed the hide
        // otherwise blanks the first 10 s of a ⇧⌘5 recording.
        guard !isPresenterModeOn else { return }
        overlayWindowManager.setHiddenForScreenshot(true)
        teachingTurnController.annotationController.setHiddenForScreenshot(true)
        screenshotHideRestoreWorkItem?.cancel()
        let restoreWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.overlayWindowManager.setHiddenForScreenshot(false)
            self.teachingTurnController.annotationController.setHiddenForScreenshot(false)
            self.screenshotHideRestoreWorkItem = nil
        }
        screenshotHideRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScreenshotChord.hideSeconds, execute: restoreWorkItem)
    }

    /// P-DISPLAYS and Spaces (§6.6): event-driven, nothing polls.
    private func observeDisplayAndSpaceChanges() {
        lastDisplayLayout = Self.currentDisplayLayout()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Overlays join every Space, so marks would sit over the wrong windows.
            MainActor.assumeIsolated {
                self?.teachingTurnController.annotationController.clearVisibleMarks()
            }
        }
    }

    /// Displays added, removed, rearranged or rescaled: the per-display overlays are rebuilt for
    /// the new layout and marks clear (they were placed for the old one).
    private func displaysChanged() {
        let displayLayout = Self.currentDisplayLayout()
        guard displayLayout != lastDisplayLayout else { return }
        lastDisplayLayout = displayLayout
        print("🖥️ Displays changed: rebuilding overlays for \(NSScreen.screens.count) display(s)")
        teachingTurnController.annotationController.displaysChanged()
        clearDetectedElementLocation()
        if isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        }
    }

    /// Each display's frame and backing scale, so arranging, resizing or rescaling counts.
    private static func currentDisplayLayout() -> [[CGFloat]] {
        NSScreen.screens.map { screen in
            [
                screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height,
                screen.backingScaleFactor,
            ]
        }
    }

    /// §4.2.2 rule 3: Esc stops Chalk talking and clears its marks within 150 ms. O(1) when idle,
    /// so every Esc the learner presses in other apps costs nothing.
    private func handleEscapeKey() {
        // During a walkthrough Esc usually belongs to the user's app (closing a dialog in
        // DaVinci): it only stops Chalk talking. The HUD's Stop or "stop" ends the walkthrough.
        if teachingTurnController.walkthroughController.isActive {
            teachingTurnController.voiceOut.stop()
            return
        }
        guard
            teachingTurnController.isBusy
                || teachingTurnController.annotationController.hasLiveMarks
        else { return }
        teachingTurnController.stopSpeakingAndDrawing()
        clearCaption(afterSeconds: 0)
        clearDetectedElementLocation()
        handleTeachingTurnStateChange(.idle)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            pendingDeveloperTextRequestTask?.cancel()
            pendingDeveloperTextRequestTask = nil
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isChalkCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)

            // Barge-in (§7.6): stop talking, abort the running turn, and start the screenshot
            // and prewarm while the learner is still speaking (D43).
            teachingTurnController.learnerStartedTalking()
            isWaitingToExplainLearnerRegion = false
            receivedTranscriptSinceKeyDown = false
            regionActionChooser.dismiss()
            // §4.2.5: while the chord is held, the learner can draw on the display under the mouse.
            let mouseLocation = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                drawChordPanel.begin(onScreen: screen)
            }
            clearCaption(afterSeconds: 0)
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ChalkAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.isWaitingToExplainLearnerRegion = false
                        self?.receivedTranscriptSinceKeyDown = true
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ChalkAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.teachingTurnController.ask(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ChalkAnalytics.trackPushToTalkReleased()
            // The panel leaves first, so the overlay is click-through again (§3.5).
            if let drawing = drawChordPanel.end() {
                isWaitingToExplainLearnerRegion = teachingTurnController.learnerDrew(
                    strokes: drawing.strokes, displayFrame: drawing.displayFrame)
            }
            teachingTurnController.learnerReleasedKey()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Teaching turns

    private var pendingDeveloperTextRequestTask: Task<Void, Never>?

    /// An explicit text trigger keeps capture/voice/draw behavior identical, without STT (D83).
    @discardableResult
    func submitDeveloperTextRequest(_ text: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: "ChalkDeveloperTextInput"),
            let request = DeveloperTextRequest.normalized(text),
            hasCompletedOnboarding, allPermissionsGranted, !showOnboardingVideo,
            !buddyDictationManager.isDictationInProgress
        else { return false }
        pendingDeveloperTextRequestTask?.cancel()
        NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
        pendingDeveloperTextRequestTask = Task { [weak self] in
            // A one-shot layout/focus settling delay, never background polling (§6.5).
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled,
                UserDefaults.standard.bool(forKey: "ChalkDeveloperTextInput"),
                self.allPermissionsGranted, !self.buddyDictationManager.isDictationInProgress
            else { return }
            self.transientHideTask?.cancel()
            self.transientHideTask = nil
            if !self.isOverlayVisible {
                self.overlayWindowManager.hasShownOverlayBefore = true
                self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                self.isOverlayVisible = true
            }
            self.regionActionChooser.dismiss()
            self.isWaitingToExplainLearnerRegion = false
            self.clearCaption(afterSeconds: 0)
            self.clearDetectedElementLocation()
            self.teachingTurnController.learnerStartedTalking()
            self.teachingTurnController.learnerReleasedKey()
            self.teachingTurnController.ask(request)
            self.pendingDeveloperTextRequestTask = nil
        }
        return true
    }

    /// §4.2.5 / §4.3: chips next to the lasso; picking one asks about the region.
    private func showRegionActionChooser() {
        guard let drawing = teachingTurnController.learnerDrawingRegion else { return }
        regionActionChooser.show(nextTo: drawing.region, displayFrame: drawing.displayFrame) {
            [weak self] action in
            self?.teachingTurnController.askAboutRegion(action)
        }
    }

    /// Runs a saved how-to again from the panel (§4.3).
    func runSavedHowTo(_ howTo: SavedHowTo) {
        NotificationCenter.default.post(name: .chalkDismissPanel, object: nil)
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        teachingTurnController.walkthroughController.run(howTo)
    }

    private func handleTeachingTurnStateChange(_ turnState: TeachingTurnController.State) {
        switch turnState {
        case .thinking:
            voiceState = .processing
        case .speaking:
            voiceState = .responding
        case .idle:
            voiceState = .idle
            clearCaption(afterSeconds: Self.captionLingerSeconds)
            scheduleTransientHideIfNeeded()
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Chalk" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isChalkCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for speech to finish
            while teachingTurnController.voiceOut.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by ChalkCursorView when onboarding starts.
    func setupOnboardingVideo() {
        // Presentation asset only: keep the existing player, fade and completion flow.
        guard let videoURL = Bundle.main.url(forResource: "ChalkIntroduction", withExtension: "mp4") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ChalkAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }
}
