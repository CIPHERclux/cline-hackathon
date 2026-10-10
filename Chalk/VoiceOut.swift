//
//  VoiceOut.swift
//  Chalk
//
//  Apple-native text-to-speech (§7.6, hard constraint): each Teaching Script `speak` line is
//  queued the moment its line completes, so Chalk starts talking while the model is still
//  writing. Anchor markers ({a1}) are stripped from what is spoken; their UTF-16 offsets go to the
//  annotation scheduler, which starts each drawing when the spoken word reaches it (§4.2.4).
//

import AVFoundation
import ChalkCore
import Foundation

@MainActor
final class VoiceOut: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var queuedUtteranceCount = 0
    /// Utterances that haven't produced their first word yet, and whether each is the
    /// "let me look" acknowledgement rather than the answer (they are timed separately, §11.3).
    private var acknowledgementFlagByUtterance: [ObjectIdentifier: Bool] = [:]
    /// Stable numbers for queued utterances (the scheduler is pure and keys by Int).
    private var utteranceNumberByUtterance: [ObjectIdentifier: Int] = [:]
    private var nextUtteranceNumber = 0

    /// Fired when an utterance's first word actually starts playing (latency log, §11.3).
    var onUtteranceStartedSpeaking: ((_ isAcknowledgement: Bool) -> Void)?
    /// Fired when everything queued has been spoken (or stopped).
    var onFinishedSpeaking: (() -> Void)?
    /// Captions (§5.4 "Speaking: captions highlight the current word"): the sentence being spoken
    /// and the range of the word being spoken right now.
    var onCaptionUpdate: ((_ spokenText: String, _ currentWordRange: NSRange) -> Void)?
    /// Word-level timing for drawings (§4.2.4): the range about to be spoken in an utterance.
    /// `callbackTime` is taken on the synthesizer's thread, before the hop to the main actor, so
    /// the S4 sync measurement includes that hop.
    var onRangeWillBeSpoken:
        ((_ utteranceNumber: Int, _ currentWordRange: NSRange, _ callbackTime: Date) -> Void)?
    /// An utterance ended or was cut, so its unfired anchors and finished groups can be handled.
    var onUtteranceFinished: ((_ utteranceNumber: Int) -> Void)?

    var isSpeaking: Bool { queuedUtteranceCount > 0 }
    /// The default rate for lines that don't set one: the teaching pace, slower in kids mode
    /// (§4.3).
    var speechRate = VoiceOut.teachingRate

    override init() {
        voice = Self.bestAvailableVoice()
        super.init()
        synthesizer.delegate = self
        if Self.usesSystemSpokenContentVoice {
            print("🔊 VoiceOut: using the Spoken Content voice from System Settings")
        } else {
            print(
                "🔊 VoiceOut: using voice \(voice?.name ?? "system default") (\(voice?.language ?? "?"))"
            )
        }
    }

    /// Queues one line. Returns its utterance number and anchor offsets, or nil when there is
    /// nothing to say.
    @discardableResult
    func speak(_ speakAction: SpeakAction, isAcknowledgement: Bool = false) -> (
        utteranceNumber: Int, anchorOffsets: [String: Int]
    )? {
        let anchoredSpeech = AnchorMapper.map(speakAction.text)
        let spokenText = anchoredSpeech.spokenText
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = voice
        if Self.usesSystemSpokenContentVoice {
            utterance.prefersAssistiveTechnologySettings = true
        }
        // A calmer teaching pace (owner, D58): a little slower than the system default, with a
        // breath between sentences and a longer one after a sentence that draws something.
        utterance.rate =
            Float(speakAction.rate ?? speechRate) * AVSpeechUtteranceDefaultSpeechRate
        var pauseAfterSeconds =
            anchoredSpeech.anchorOffsets.isEmpty
            ? Self.pauseBetweenSentencesSeconds : Self.pauseAfterDrawingSentenceSeconds
        if let pauseAfterMilliseconds = speakAction.pauseAfterMilliseconds {
            pauseAfterSeconds = Double(pauseAfterMilliseconds) / 1000
        }
        queuedUtteranceCount += 1
        acknowledgementFlagByUtterance[ObjectIdentifier(utterance)] = isAcknowledgement
        nextUtteranceNumber += 1
        utteranceNumberByUtterance[ObjectIdentifier(utterance)] = nextUtteranceNumber
        waitingUtterances.append((utterance, pauseAfterSeconds))
        speakNextIfIdle()
        return (nextUtteranceNumber, anchoredSpeech.anchorOffsets)
    }

    // MARK: - Own queue (D73)

    /// Chalk hands the synthesizer one sentence at a time and keeps the rest itself, so the
    /// pause after a sentence can wait for the whiteboard's pen. Pausing and resuming the
    /// synthesizer between queued utterances crashed AVFoundation ("Tried to speak an utterance
    /// that is already speaking", owner's simplex run, D73).
    private var waitingUtterances: [(utterance: AVSpeechUtterance, pauseAfterSeconds: Double)] = []
    private var speakingUtterance: (utterance: AVSpeechUtterance, pauseAfterSeconds: Double)?
    private var gapTask: Task<Void, Never>?
    /// True while the next sentence should wait (the board is still writing the last line).
    var shouldHoldNextSentence: (() -> Bool)?
    /// A hold never outlasts this, whatever the board does.
    static let longestBoardHoldSeconds = 8.0

    private func speakNextIfIdle() {
        guard speakingUtterance == nil, gapTask == nil, !waitingUtterances.isEmpty else { return }
        let next = waitingUtterances.removeFirst()
        speakingUtterance = next
        synthesizer.speak(next.utterance)
    }

    /// Barge-in (§7.6): stop at the end of the current word, drop everything queued.
    func stop() {
        gapTask?.cancel()
        gapTask = nil
        waitingUtterances.removeAll()
        let wasSpeaking = isSpeaking
        if speakingUtterance != nil || synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        // Its cancel callback is ignored: a new sentence may already be queued by then.
        speakingUtterance = nil
        queuedUtteranceCount = 0
        acknowledgementFlagByUtterance.removeAll()
        utteranceNumberByUtterance.removeAll()
        if wasSpeaking { onFinishedSpeaking?() }
    }

    /// Chalk's default voice: the owner's Premium download. Siri voices (e.g. "Voice 6") are not
    /// listed to apps, only to command-line tools (checked in S04: the app ranked Siri voices first
    /// and still got Ava), so they can't be the default.
    /// Owner: "speech is too fast to explain properly" (D58, then D65).
    static let teachingRate = 0.78
    static let pauseBetweenSentencesSeconds = 0.6
    static let pauseAfterDrawingSentenceSeconds = 1.0

    static let preferredVoiceIdentifiers = [
        "com.apple.voice.premium.en-US.Ava", "com.apple.voice.premium.en-US.Zoe",
    ]
    static let voiceIdentifierDefaultsKey = "ChalkVoiceIdentifier"
    /// `defaults write com.yourcompany.leanring-buddy ChalkVoiceIdentifier system` speaks with the
    /// voice chosen in System Settings › Accessibility › Spoken Content, which can be a Siri voice.
    static let systemSpokenContentVoiceSetting = "system"

    /// True when the owner asked for the Spoken Content voice (see above).
    static var usesSystemSpokenContentVoice: Bool {
        UserDefaults.standard.string(forKey: voiceIdentifierDefaultsKey)
            == systemSpokenContentVoiceSetting
    }

    /// Voice choice: an explicit override, then the preferred Premium voices, then the most natural
    /// installed voice for the Mac's language (premium, then enhanced). Nil means "let the system
    /// decide", used with the Spoken Content setting.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        if usesSystemSpokenContentVoice { return nil }
        let overrideIdentifier = UserDefaults.standard.string(forKey: voiceIdentifierDefaultsKey)
        for identifier in ([overrideIdentifier].compactMap { $0 } + preferredVoiceIdentifiers) {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        }
        let languageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let languagePrefix = String(languageCode.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == languageCode || $0.language.hasPrefix(languagePrefix)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            (voice.quality.rawValue, voice.language == languageCode ? 1 : 0)
        }
        let ranked = candidates.sorted { rank($0) > rank($1) }
        return ranked.first ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    fileprivate func handleWillSpeakRange(
        utteranceIdentifier: ObjectIdentifier, spokenText: String, currentWordRange: NSRange,
        callbackTime: Date
    ) {
        onCaptionUpdate?(spokenText, currentWordRange)
        if let utteranceNumber = utteranceNumberByUtterance[utteranceIdentifier] {
            onRangeWillBeSpoken?(utteranceNumber, currentWordRange, callbackTime)
        }
        guard
            let isAcknowledgement = acknowledgementFlagByUtterance.removeValue(
                forKey: utteranceIdentifier)
        else { return }
        onUtteranceStartedSpeaking?(isAcknowledgement)
    }

    fileprivate func handleUtteranceEnded(utteranceIdentifier: ObjectIdentifier) {
        // Only the sentence being spoken counts; a cancel from before stop() is ignored.
        guard let finished = speakingUtterance,
            ObjectIdentifier(finished.utterance) == utteranceIdentifier
        else { return }
        speakingUtterance = nil
        acknowledgementFlagByUtterance.removeValue(forKey: utteranceIdentifier)
        if let utteranceNumber = utteranceNumberByUtterance.removeValue(
            forKey: utteranceIdentifier)
        {
            onUtteranceFinished?(utteranceNumber)
        }
        queuedUtteranceCount = max(0, queuedUtteranceCount - 1)
        if queuedUtteranceCount == 0 {
            onFinishedSpeaking?()
            return
        }
        // The breath after the sentence, then wait for the pen if the board is still writing
        // the line this sentence revealed (D72), at most 8 s.
        gapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(finished.pauseAfterSeconds))
            let holdStartedAt = Date()
            while !Task.isCancelled, self?.shouldHoldNextSentence?() == true,
                Date().timeIntervalSince(holdStartedAt) < Self.longestBoardHoldSeconds
            {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let self, !Task.isCancelled else { return }
            self.gapTask = nil
            self.speakNextIfIdle()
        }
    }
}

extension VoiceOut: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let callbackTime = Date()
        let utteranceIdentifier = ObjectIdentifier(utterance)
        let spokenText = utterance.speechString
        Task { @MainActor in
            self.handleWillSpeakRange(
                utteranceIdentifier: utteranceIdentifier, spokenText: spokenText,
                currentWordRange: characterRange, callbackTime: callbackTime)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.handleUtteranceEnded(utteranceIdentifier: utteranceIdentifier) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.handleUtteranceEnded(utteranceIdentifier: utteranceIdentifier) }
    }
}
