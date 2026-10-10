//
//  SpeechService.swift
//  Chalk
//
//  On-device speech-to-text with SpeechAnalyzer + SpeechTranscriber (macOS 26, §7.6). Audio never
//  leaves the Mac (§10.1). Volatile results give live text; finalized results build the prompt.
//  Plugs into BuddyDictationManager through the BuddyTranscriptionProvider protocol, which keeps
//  owning the microphone (AVAudioEngine) and the push-to-talk flow.
//

import AVFoundation
import Foundation
import Speech

struct SpeechServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SpeechService {
    /// The transcriber's locale: the Mac's language when supported, else US English.
    static func transcriberLocale() async -> Locale {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return supported
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Volatile results let the prompt be ready the moment the key is released; fastResults
        // trades a little accuracy for latency, which matters more for a conversation (§11.3).
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Downloads the on-device speech model if it is missing. Called at launch so the first
    /// key press doesn't wait for a download (§7.6 "the locale asset is installed during onboarding").
    static func prepareSpeechAssetsIfNeeded() async {
        let transcriber = makeTranscriber(locale: await transcriberLocale())
        do {
            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("🎙️ SpeechService: downloading the on-device speech model…")
                try await installationRequest.downloadAndInstall()
                print("🎙️ SpeechService: speech model installed")
            }
        } catch {
            print("⚠️ SpeechService: could not prepare the speech model: \(error)")
        }
    }
}

final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple SpeechAnalyzer (on-device)"
    // SpeechAnalyzer runs on-device with the microphone permission alone; it does not use the
    // SFSpeechRecognizer authorization (owner verifies on first run, see S04 "could not verify").
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechServiceError(message: "on-device speech recognition isn't available on this mac.")
        }
        let transcriber = SpeechService.makeTranscriber(locale: await SpeechService.transcriberLocale())
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechServiceError(message: "the speech model isn't ready yet. try again in a moment.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // App and skill-pack vocabulary as hints (§7.6 "custom vocabulary from the skill pack").
        if !keyterms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = keyterms
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let session = SpeechAnalyzerTranscriptionSession(
            analyzer: analyzer, transcriber: transcriber, analyzerFormat: analyzerFormat,
            onTranscriptUpdate: onTranscriptUpdate, onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
        try await session.start()
        return session
    }
}

private final class SpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    /// After key-up, finalization normally completes in a few hundred ms; this is only the
    /// safety net if it never reports back.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let analyzerFormat: AVAudioFormat
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    // Touched from the audio thread (append) and the results task; guarded by the lock.
    private let lock = NSLock()
    private var audioConverter: AVAudioConverter?
    private var finalizedText = ""
    private var volatileText = ""
    private var resultsTask: Task<Void, Never>?

    init(
        analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, analyzerFormat: AVAudioFormat,
        onTranscriptUpdate: @escaping (String) -> Void, onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.analyzerFormat = analyzerFormat
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    func start() async throws {
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters)
                    let combinedText = self.lock.withLock { () -> String in
                        if result.isFinal {
                            self.finalizedText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        return self.finalizedText + self.volatileText
                    }
                    self.onTranscriptUpdate(combinedText)
                }
                let finalText = self.lock.withLock { self.finalizedText + self.volatileText }
                self.onFinalTranscriptReady(finalText.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.onError(error)
            }
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let convertedBuffer = convertToAnalyzerFormat(audioBuffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    func requestFinalTranscript() {
        inputContinuation.finish()
        Task { [analyzer, onError] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                onError(error)
            }
        }
    }

    func cancel() {
        inputContinuation.finish()
        resultsTask?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    /// The microphone's native format (often 48 kHz float) → the analyzer's format.
    private func convertToAnalyzerFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if inputFormat == analyzerFormat { return buffer }
        let converter: AVAudioConverter? = lock.withLock {
            if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
                audioConverter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            }
            return audioConverter
        }
        guard let converter else { return nil }
        let outputCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * analyzerFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outputCapacity) else { return nil }
        var hasProvidedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return conversionError == nil && outputBuffer.frameLength > 0 ? outputBuffer : nil
    }
}
