//
//  ChalkAnalytics.swift
//  Chalk
//
//  Analytics are switched off for the demo (D14, §3.8 "local first", §11.6). The original
//  build sent full transcripts and AI responses to PostHog. The call sites stay so the opt-in,
//  content-free telemetry of §11.6 (MVP) can plug in here later; today every method does nothing
//  and the PostHog package is no longer linked.
//

import Foundation

enum ChalkAnalytics {
    static func configure() {}
    static func trackAppOpened() {}
    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingVideoCompleted() {}
    static func trackOnboardingDemoTriggered() {}
    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}
    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}
    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
