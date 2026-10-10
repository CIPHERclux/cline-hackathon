//
//  GroundingService.swift
//  Chalk
//
//  The two grounding steps that need the screen or a model (§6.2 d and f); the decisions are
//  pure and tested in ChalkCore (VerificationCheck, ZoomPass, GroundingEscalation).
//  - Verify: after a mark is drawn, re-capture a full-height column around it, OCR it, and check
//    the label is still inside the mark (it moves if the page scrolled).
//  - Zoom: a target the model only guessed (nothing to snap to) gets a second look: a
//    native-resolution crop around the guess goes to the grounding slot (§7.4 rule 4), which
//    points again; the answer snaps to fresh candidates found in that crop.
//

import ChalkCore
import CoreGraphics
import Foundation
import os

@MainActor
final class GroundingService {
    /// §6.2 (f): "re-capture a 300×300 pt crop around the target" (the column's minimum width).
    static let verificationCropSidePoints: CGFloat = 300
    /// A zoom answer that hasn't arrived by then is a failure (the sentence has moved on).
    static let zoomTimeoutSeconds: Double = 20

    private static let log = Logger(subsystem: "com.chalk.app", category: "grounding")
    private let engineHost: TutorEngineHost

    init(engineHost: TutorEngineHost) {
        self.engineHost = engineHost
    }

    // MARK: - Verify (§6.2 f)

    func verify(
        expectedText: String, markRectInNativePixels markRect: CGRect, screenSpace: ScreenSpace
    )
        async -> VerificationVerdict
    {
        let startedAt = Date()
        // A full-height column rather than §6.2 f's 300×300 pt square: hand test 2 scrolled the
        // label out of the square, so it was "not found" instead of moved. OCR on a column costs
        // about the same (one tile wide).
        let markWidthInPoints = markRect.width / screenSpace.backingScale
        let crop = ZoomPass.cropRect(
            around: CGPoint(x: markRect.midX, y: markRect.midY), screenSpace: screenSpace,
            sizeInPoints: CGSize(
                width: max(Self.verificationCropSidePoints, markWidthInPoints + 200),
                height: screenSpace.displayFrameInAppKitGlobal.height))
        guard
            let image = try? await CaptureService.captureRegion(
                nativePixelRect: crop, screenSpace: screenSpace)
        else {
            return .notVerifiable
        }
        let ocrLines = await Self.textMarks(in: image, offsetBy: crop.origin)
        let verdict = VerificationCheck.verify(
            expectedText: expectedText, markRect: markRect, ocrLines: ocrLines)
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        Self.log.notice(
            "🎯 verify \"\(expectedText, privacy: .public)\" → \(String(describing: verdict), privacy: .public) in \(milliseconds) ms"
        )
        return verdict
    }

    // MARK: - Zoom (§6.2 d)

    /// Returns the target's rect in native pixels, or nil when the model can't find it.
    func zoomPass(
        around guess: CGPoint, lookingFor description: String, capture: ScreenCaptureResult,
        slot: ModelSlot
    ) async -> CGRect? {
        let startedAt = Date()
        let crop = ZoomPass.cropRect(around: guess, screenSpace: capture.screenSpace)
        guard let client = engineHost.client, let router = engineHost.router,
            let model = try? router.candidateModels(for: slot, requiresVision: true).first,
            let cropImage = capture.nativeImage.cropping(to: crop),
            let jpeg = MarksImageRenderer.jpegData(cropImage)
        else { return nil }
        // The fast path (D74): one direct call, no agent loop or rule files.
        let reply = await Self.collectReply(
            from: await client.completeTurn(
                slot: slot.rawValue, model: model,
                system: TeachingTurnController.fastPathSystemPrompt,
                prompt: ZoomPass.prompt(lookingFor: description),
                imageDataURLs: ["data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                maxTokens: 8192),
            timeoutSeconds: Self.zoomTimeoutSeconds, client: client)
        guard let reply, let norm1000 = ZoomPass.pointedNorm1000(in: reply) else {
            Self.log.notice(
                "🎯 zoom \"\(description, privacy: .public)\" (\(slot.rawValue, privacy: .public)) → not found"
            )
            return nil
        }
        let nativePoint = ZoomPass.nativePoint(fromNorm1000: norm1000, in: crop)
        // Fresh local candidates in the crop (§6.2 d): the answer snaps to a real outline.
        let candidates = await Self.marks(in: cropImage, offsetBy: crop.origin)
        let snapped = MarkSelection.smallestMark(containing: nativePoint, in: candidates)
        let side = 32 * capture.screenSpace.backingScale
        let rect =
            snapped?.box
            ?? CGRect(
                x: nativePoint.x - side / 2, y: nativePoint.y - side / 2, width: side, height: side)
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        Self.log.notice(
            "🎯 zoom \"\(description, privacy: .public)\" (\(slot.rawValue, privacy: .public)) → \(snapped == nil ? "unsnapped" : "snapped", privacy: .public) in \(milliseconds) ms"
        )
        return rect
    }

    // MARK: - Helpers

    /// The streamed text of one reply, or nil on error or timeout.
    static func collectReply(
        from stream: AsyncStream<EngineEvent>, timeoutSeconds: Double,
        client: TutorEngineClient? = nil
    ) async -> String? {
        await EngineReplyCollector.collect(
            from: stream, client: client,
            timeoutSeconds: timeoutSeconds)?.text
    }

    /// Vision candidates in a crop, moved into the display's native pixel space.
    private static func marks(in image: CGImage, offsetBy origin: CGPoint) async -> [Mark] {
        await Task.detached(priority: .userInitiated) {
            let candidates = (try? VisionCandidateDetector.detectCandidates(in: image)) ?? []
            return candidates.enumerated().map { index, candidate in
                Mark(
                    id: index, kind: candidate.kind, text: candidate.text,
                    box: candidate.box.offsetBy(dx: origin.x, dy: origin.y))
            }
        }.value
    }

    private static func textMarks(in image: CGImage, offsetBy origin: CGPoint) async -> [Mark] {
        await marks(in: image, offsetBy: origin).filter { $0.kind == .text }
    }
}
