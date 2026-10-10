// Plays the same teaching sentence in each natural-sounding English voice on this Mac, so the
// owner can pick Chalk's voice by ear (§7.6 TTS is AVSpeechSynthesizer only).
// Usage: swift Eval/voice-sampler.swift            (then set the one you like:)
//        defaults write com.yourcompany.leanring-buddy ChalkVoiceIdentifier <identifier>
import AVFoundation

let sampleSentence = "Good eye. Swapping this sum and this integral isn't automatic. Let's see why."
let synthesizer = AVSpeechSynthesizer()

let voices = AVSpeechSynthesisVoice.speechVoices()
    .filter { $0.language.hasPrefix("en") && ($0.identifier.hasPrefix("com.apple.siri.") || $0.quality != .default) }
    .sorted { ($0.identifier.hasPrefix("com.apple.siri.") ? 0 : 1, -$0.quality.rawValue, $0.name) < ($1.identifier.hasPrefix("com.apple.siri.") ? 0 : 1, -$1.quality.rawValue, $1.name) }

if voices.isEmpty {
    print("No natural voices installed. Add one in System Settings › Accessibility › Spoken Content › System voice › Manage Voices…")
}
for (index, voice) in voices.enumerated() {
    let quality = voice.identifier.hasPrefix("com.apple.siri.") ? "Siri" : voice.quality == .premium ? "Premium" : "Enhanced"
    print("\(index + 1). \(voice.name) [\(quality), \(voice.language)]  →  \(voice.identifier)")
    let utterance = AVSpeechUtterance(string: sampleSentence)
    utterance.voice = voice
    synthesizer.speak(utterance)
    // Wait for this voice to start, then to finish, before naming the next one.
    let startDeadline = Date().addingTimeInterval(3)
    while !synthesizer.isSpeaking && Date() < startDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    while synthesizer.isSpeaking { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
}
