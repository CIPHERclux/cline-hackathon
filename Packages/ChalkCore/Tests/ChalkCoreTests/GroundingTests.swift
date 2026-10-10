import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Fuzzy text match (§6.2 text anchors)")
struct FuzzyTextMatchTests {
    @Test("exact beats prefix beats contains beats an OCR-typo match")
    func ranks() {
        #expect(FuzzyTextMatch.rank(candidate: "Export", wanted: "export") == 0)
        #expect(FuzzyTextMatch.rank(candidate: "Export as PDF…", wanted: "Export") == 1)
        #expect(FuzzyTextMatch.rank(candidate: "Quick Export", wanted: "export") == 2)
        // OCR misread "Auto layout" as "Aut0 1ayout".
        #expect(FuzzyTextMatch.rank(candidate: "Aut0 1ayout", wanted: "Auto layout") == 3)
        #expect(FuzzyTextMatch.rank(candidate: "Settings", wanted: "Export") == nil)
    }

    @Test("short words need an exact or prefix match, so 'OK' doesn't match 'on'")
    func shortWordsAreStrict() {
        #expect(FuzzyTextMatch.rank(candidate: "on", wanted: "OK") == nil)
        #expect(FuzzyTextMatch.rank(candidate: "ok", wanted: "OK") == 0)
    }

    @Test("similarity is 1 for equal strings and falls with edits")
    func similarity() {
        #expect(FuzzyTextMatch.similarity("layout", "layout") == 1)
        #expect(FuzzyTextMatch.similarity("layout", "1ayout") > 0.8)
        #expect(FuzzyTextMatch.similarity("layout", "export") < 0.6)
    }
}

@Suite("Target resolution order and disambiguation (§6.2)")
struct ResolutionOrderTests {
    static let screenSpace = ScreenSpace(
        displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1000, height: 600),
        nativePixelSize: CGSize(width: 2000, height: 1200),
        modelPixelSize: CGSize(width: 1000, height: 600))
    static let snapTargets = [
        Mark(
            id: 1, kind: .text, text: "Layers", box: CGRect(x: 100, y: 100, width: 120, height: 30)),
        Mark(
            id: 2, kind: .text, text: "Export", box: CGRect(x: 100, y: 300, width: 120, height: 30)),
        Mark(
            id: 3, kind: .text, text: "Assets", box: CGRect(x: 1500, y: 100, width: 120, height: 30)
        ),
        Mark(
            id: 4, kind: .text, text: "Export", box: CGRect(x: 1500, y: 300, width: 120, height: 30)
        ),
    ]

    var resolver: TargetResolver {
        TargetResolver(
            screenSpace: Self.screenSpace, marks: Array(Self.snapTargets.prefix(2)),
            snapTargets: Self.snapTargets, cursorInNativePixels: CGPoint(x: 0, y: 0))
    }

    @Test("within picks the match under the named heading, not the one nearest the cursor")
    func withinDisambiguates() {
        let resolved = resolver.resolve(.text("Export", near: nil, within: "Assets"))
        #expect(resolved?.rectInNativePixels.minX == 1500)
        let nearCursor = resolver.resolve(.text("Export", near: nil, within: nil))
        #expect(nearCursor?.rectInNativePixels.minX == 100)
    }

    @Test("ranked alternatives list every match, best first (for the next-best retry)")
    func rankedAlternatives() {
        let alternatives = resolver.rankedTextMatches(for: "Export", near: CGPoint(x: 1600, y: 300))
        #expect(alternatives.map(\.id) == [4, 2])
    }

    @Test("a raw px target with nothing under it is low confidence; a snapped one isn't")
    func pixelConfidence() {
        let overNothing = resolver.resolve(.pixel(x: 500, y: 900, space: "norm1000"))
        #expect(overNothing?.isLowConfidence == true)
        #expect(overNothing?.source == .rawPoint)
        // norm1000 (80, 95.8) → model (80, 57.5) → native (160, 115): inside "Layers".
        let onLayers = resolver.resolve(.pixel(x: 80, y: 95.8, space: "norm1000"))
        #expect(onLayers?.isLowConfidence == false)
        #expect(onLayers?.source == .snappedPoint)
    }
}

@Suite("Verification (§6.2 f)")
struct VerificationTests {
    static let label = Mark(
        id: 9, kind: .text, text: "Export", box: CGRect(x: 400, y: 400, width: 100, height: 24))

    @Test("the expected text inside the mark confirms it")
    func confirmed() {
        let verdict = VerificationCheck.verify(
            expectedText: "export", markRect: CGRect(x: 390, y: 390, width: 130, height: 50),
            ocrLines: [Self.label])
        #expect(verdict == .confirmed)
    }

    @Test("the text found elsewhere in the crop relocates the mark (the page scrolled)")
    func relocated() {
        let verdict = VerificationCheck.verify(
            expectedText: "Export", markRect: CGRect(x: 400, y: 200, width: 100, height: 24),
            ocrLines: [Self.label])
        #expect(verdict == .relocated(Self.label.box))
    }

    @Test("no match anywhere fails; no expected text can't be verified")
    func notFoundAndNotVerifiable() {
        let verdict = VerificationCheck.verify(
            expectedText: "Print", markRect: Self.label.box, ocrLines: [Self.label])
        #expect(verdict == .notFound)
        let unverifiable = VerificationCheck.verify(
            expectedText: nil, markRect: Self.label.box, ocrLines: [Self.label])
        #expect(unverifiable == .notVerifiable)
    }

    @Test("two failures escalate the zoom pass to the deep slot (§7.4 rule 5)")
    func escalation() {
        var escalation = GroundingEscalation()
        #expect(escalation.zoomSlot == .grounding)
        escalation.recordFailure()
        #expect(escalation.zoomSlot == .grounding)
        #expect(!escalation.shouldAskLearnerToCircle)
        escalation.recordFailure()
        #expect(escalation.zoomSlot == .deep)
        #expect(escalation.shouldAskLearnerToCircle)
        escalation.reset()
        #expect(escalation.zoomSlot == .grounding)
    }
}

@Suite("Zoom pass geometry (§6.2 d)")
struct ZoomPassTests {
    static let screenSpace = ScreenSpace(
        displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982),
        nativePixelSize: CGSize(width: 3024, height: 1964),
        modelPixelSize: CGSize(width: 1568, height: 1018))

    @Test("the crop is 360×240 pt around the guess, at native pixels")
    func cropAroundGuess() {
        let crop = ZoomPass.cropRect(
            around: CGPoint(x: 1500, y: 1000), screenSpace: Self.screenSpace)
        #expect(crop == CGRect(x: 1140, y: 760, width: 720, height: 480))
    }

    @Test("a crop near an edge slides inside the display instead of shrinking")
    func cropClampedToDisplay() {
        let crop = ZoomPass.cropRect(around: CGPoint(x: 20, y: 1950), screenSpace: Self.screenSpace)
        #expect(crop == CGRect(x: 0, y: 1484, width: 720, height: 480))
    }

    @Test("a 0–1000 answer about the crop maps back to native pixels of the display")
    func mapsBack() {
        let crop = CGRect(x: 1140, y: 760, width: 720, height: 480)
        let point = ZoomPass.nativePoint(fromNorm1000: CGPoint(x: 500, y: 250), in: crop)
        #expect(point == CGPoint(x: 1500, y: 880))
    }

    @Test("the reply's first point or draw target is read; an `end` alone means not found")
    func parsesReply() {
        let reply =
            #"{"type":"point","target":{"px":[120,880],"space":"norm1000"},"label":"Run"}"# + "\n"
            + #"{"type":"end"}"#
        #expect(ZoomPass.pointedNorm1000(in: reply) == CGPoint(x: 120, y: 880))
        #expect(ZoomPass.pointedNorm1000(in: #"{"type":"end"}"#) == nil)
        let fenced =
            "```json\n" + #"{"type":"draw","shape":"ring","target":{"px":[10,20]}}"# + "\n```"
        #expect(ZoomPass.pointedNorm1000(in: fenced) == CGPoint(x: 10, y: 20))
    }
}

@Suite("Rect conversions for verification")
struct VerificationRectTests {
    @Test("display points ↔ native pixels round-trip")
    func roundTrip() {
        let screenSpace = ZoomPassTests.screenSpace
        let native = CGRect(x: 100, y: 60, width: 240, height: 48)
        let points = screenSpace.nativePixelRectToDisplayPoints(native)
        #expect(points == CGRect(x: 50, y: 30, width: 120, height: 24))
        #expect(screenSpace.displayPointRectToNativePixels(points) == native)
    }
}

@Suite("Verifiable text (hand test: OCR'd maths removed correct marks)")
struct VerifiableTextTests {
    @Test("words are verifiable; maths and symbol soup are not")
    func verifiable() {
        #expect(VerificationCheck.isVerifiable("History"))
        #expect(VerificationCheck.isVerifiable("Euclidean distance"))
        #expect(!VerificationCheck.isVerifiable("V{ € R.(Eq.1)"))
        #expect(!VerificationCheck.isVerifiable("F(Đ) = [-00"))
        #expect(!VerificationCheck.isVerifiable("OK"))
    }
}

@Suite("Text targets fall back to their point (D73)")
struct TextTargetFallbackTests {
    @Test("an unreadable label resolves to the point given beside it")
    func fallback() {
        let screenSpace = ScreenSpace(
            displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            nativePixelSize: CGSize(width: 1000, height: 1000),
            modelPixelSize: CGSize(width: 1000, height: 1000))
        let resolver = TargetResolver(
            screenSpace: screenSpace, marks: [], snapTargets: [], cursorInNativePixels: nil)
        let target = TargetDescriptor.text(
            "Where to?", near: .pixel(x: 500, y: 200, space: "norm1000"), within: nil)
        let resolved = resolver.resolve(target)
        #expect(resolved != nil)
        #expect(resolved.map { abs($0.rectInNativePixels.midX - 500) < 1 } == true)
        #expect(resolver.resolve(.text("Where to?", near: nil, within: nil)) == nil)
    }
}
