//
//  BuddyTranscriptionProvider.swift
//  Chalk
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

/// Speech-to-text is Apple-native and on-device only: SpeechAnalyzer + SpeechTranscriber on
/// macOS 26 (§7.6, hard constraint). The cloud providers (AssemblyAI, OpenAI) are gone (D13).
enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        SpeechAnalyzerTranscriptionProvider()
    }
}
