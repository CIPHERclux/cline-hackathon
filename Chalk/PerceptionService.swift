//
//  PerceptionService.swift
//  Chalk
//
//  §6.2 (b): Apple Vision candidates on the native capture → marks, off the main thread and
//  started at key-down, so it overlaps the learner speaking (§7.6 latency trick). Two sets
//  (D48): capped marks for a set-of-marks prompt, and uncapped snap targets for turning a model's
//  point into an exact outline (S06/S08) and for the verify pass.
//

import AppKit
import ChalkCore
import CoreGraphics
import Foundation

struct ScreenPerception: Sendable {
    let marks: [Mark]
    let snapTargets: [Mark]
    let candidateCount: Int
    let milliseconds: Int
}

enum PerceptionService {
    static func perceive(_ capture: ScreenCaptureResult) async -> ScreenPerception? {
        let nativeImage = capture.nativeImage
        let focusRect = capture.frontmostWindowRectInNativePixels
        let cursor = capture.cursorInNativePixels
        // D74: the front app's accessibility tree is read alongside OCR; its controls join the
        // snap targets, so a circle lands on the real button rather than on OCR'd text near it.
        let mainDisplayHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
        async let accessibility = AccessibilityService.snapshotOfFrontmostApp()
        let vision = await Task.detached(priority: .userInitiated) {
            () -> (marks: [Mark], snapTargets: [Mark], candidateCount: Int, startedAt: Date)? in
            let startedAt = Date()
            guard let candidates = try? VisionCandidateDetector.detectCandidates(in: nativeImage)
            else { return nil }
            let marks = MarkSelection.selectMarks(
                from: candidates, focusRect: focusRect, cursor: cursor)
            let snapTargets = MarkSelection.selectMarks(
                from: candidates, limits: .unlimited, focusRect: focusRect, cursor: cursor)
            return (marks, snapTargets, candidates.count, startedAt)
        }.value
        let snapshot = await accessibility
        guard let vision else { return nil }
        let accessibilityTargets = snapshot.map {
            accessibilityMarks(
                from: $0, screenSpace: capture.screenSpace, mainDisplayHeight: mainDisplayHeight)
        } ?? []
        return ScreenPerception(
            marks: vision.marks, snapTargets: accessibilityTargets + vision.snapTargets,
            candidateCount: vision.candidateCount + accessibilityTargets.count,
            milliseconds: Int(Date().timeIntervalSince(vision.startedAt) * 1000))
    }

    /// Controls worth pointing at, as marks in the capture's native pixels: named ones as text
    /// (so `{"text":"Export"}` finds the button itself), unnamed ones as boxes to snap to.
    static let pointableRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXTextField", "AXTextArea", "AXComboBox",
        "AXSearchField", "AXLink", "AXMenuBarItem", "AXMenuItem", "AXRadioButton", "AXTab",
        "AXCheckBox", "AXSwitch", "AXDisclosureTriangle", "AXHeading", "AXImage", "AXCell",
    ]

    private static func accessibilityMarks(
        from snapshot: AccessibilitySnapshot, screenSpace: ScreenSpace, mainDisplayHeight: CGFloat
    ) -> [Mark] {
        let visibleArea = screenSpace.accessibilityVisibleArea(mainDisplayHeight: mainDisplayHeight)
        var marks: [Mark] = []
        for node in snapshot.nodes
        where pointableRoles.contains(node.role) && visibleArea.intersects(node.frame) {
            let box = screenSpace.accessibilityRectToNativePixels(
                node.frame, mainDisplayHeight: mainDisplayHeight)
            let name = node.names.first
            marks.append(
                Mark(
                    id: 100_000 + marks.count, kind: name == nil ? .box : .text, text: name,
                    box: box))
        }
        return marks
    }

    /// Vision's first accurate-OCR request loads its model (~24 s cold); do it at launch.
    static func warmUpInBackground() {
        Task.detached(priority: .utility) { VisionCandidateDetector.warmUp() }
    }
}
