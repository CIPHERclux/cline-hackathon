import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Anchors (§4.2.4)")
struct AnchorTests {
    @Test("anchor offsets point at the anchored word after the markers are stripped")
    func anchorOffsets() {
        let mapped = AnchorMapper.map(
            "Good eye. Swapping {a1}this sum and {a2}this integral isn't automatic.")
        #expect(
            mapped.spokenText == "Good eye. Swapping this sum and this integral isn't automatic.")
        let spoken = mapped.spokenText as NSString
        #expect(
            spoken.substring(with: NSRange(location: mapped.anchorOffsets["a1"]!, length: 8))
                == "this sum")
        #expect(
            spoken.substring(with: NSRange(location: mapped.anchorOffsets["a2"]!, length: 13))
                == "this integral")
    }

    @Test("offsets are UTF-16, matching AVSpeechSynthesizer ranges, and literal braces survive")
    func utf16AndLiteralBraces() {
        let mapped = AnchorMapper.map("∫ and ∑ {a1}here, but {not a marker} stays")
        #expect(mapped.spokenText == "∫ and ∑ here, but {not a marker} stays")
        let spoken = mapped.spokenText as NSString
        #expect(
            spoken.substring(with: NSRange(location: mapped.anchorOffsets["a1"]!, length: 4))
                == "here")
    }

    @Test("a drawing waits for its anchor and starts on the anchored word")
    func drawingWaitsForAnchor() {
        let mapped = AnchorMapper.map("Look at {a1}this button now")
        var scheduler = AnchorScheduler()
        scheduler.utteranceQueued(
            utteranceIdentifier: 1, group: "g1", anchorOffsets: mapped.anchorOffsets)
        let result1 = scheduler.drawingArrived(markIdentifier: "s1", anchor: "a1")
        #expect(result1 == false)
        let result2 = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 0, length: 4))
        #expect(result2.isEmpty)
        let result3 = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 5, length: 2))
        #expect(result3.isEmpty)
        let result4 = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 8, length: 4))
        #expect(result4 == ["s1"])
    }

    @Test("no anchor or a passed anchor starts right away")
    func immediateDrawings() {
        var scheduler = AnchorScheduler()
        scheduler.utteranceQueued(utteranceIdentifier: 1, group: nil, anchorOffsets: ["a1": 0])
        let result5 = scheduler.drawingArrived(markIdentifier: "s1", anchor: nil)
        #expect(result5)
        _ = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 0, length: 3))
        let result7 = scheduler.drawingArrived(markIdentifier: "s3", anchor: "a1")
        #expect(result7)
    }

    @Test("a drawing sent before its sentence waits for the anchor word (D50)")
    func drawingBeforeItsSentence() {
        var scheduler = AnchorScheduler()
        let arrivedFirst = scheduler.drawingArrived(markIdentifier: "s1", anchor: "a1")
        #expect(!arrivedFirst)
        scheduler.utteranceQueued(utteranceIdentifier: 1, group: "g1", anchorOffsets: ["a1": 6])
        let beforeWord = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 0, length: 5))
        #expect(beforeWord.isEmpty)
        let onWord = scheduler.rangeWillBeSpoken(
            utteranceIdentifier: 1, range: NSRange(location: 6, length: 4))
        #expect(onWord == ["s1"])
    }

    @Test("a drawing whose anchor is never declared starts when the script ends")
    func undeclaredAnchorFlush() {
        var scheduler = AnchorScheduler()
        let waiting = scheduler.drawingArrived(markIdentifier: "s2", anchor: "missing")
        #expect(!waiting)
        scheduler.utteranceQueued(utteranceIdentifier: 1, group: nil, anchorOffsets: ["a1": 0])
        let pendingOnDeclared = scheduler.drawingArrived(markIdentifier: "s3", anchor: "a1")
        #expect(!pendingOnDeclared)
        let flushed = scheduler.flushUndeclared()
        #expect(flushed == ["s2"])
        let flushedAgain = scheduler.flushUndeclared()
        #expect(flushedAgain.isEmpty)
    }

    @Test("an utterance ending flushes drawings whose anchor never fired, and finishes its group")
    func utteranceEndFlushes() {
        var scheduler = AnchorScheduler()
        scheduler.utteranceQueued(utteranceIdentifier: 1, group: "g1", anchorOffsets: ["a1": 40])
        scheduler.utteranceQueued(utteranceIdentifier: 2, group: "g1", anchorOffsets: [:])
        _ = scheduler.drawingArrived(markIdentifier: "s1", anchor: "a1")
        let first = scheduler.utteranceFinished(utteranceIdentifier: 1)
        #expect(first.drawingsToStart == ["s1"])
        #expect(first.finishedGroups.isEmpty)
        let result8 = scheduler.utteranceFinished(utteranceIdentifier: 2)
        #expect(result8.finishedGroups == ["g1"])
    }

    @Test("recorded timing events replay identically (§6.4 determinism)")
    func replayDeterminism() {
        func replay() -> [String] {
            var scheduler = AnchorScheduler()
            var started: [String] = []
            let mapped = AnchorMapper.map(
                "Swapping {a1}this sum and {a2}this integral isn't automatic.")
            scheduler.utteranceQueued(
                utteranceIdentifier: 7, group: "g1", anchorOffsets: mapped.anchorOffsets)
            for (mark, anchor) in [("s1", "a1"), ("s2", "a2"), ("s3", "a2")]
            where scheduler.drawingArrived(markIdentifier: mark, anchor: anchor) {
                started.append(mark)
            }
            // Recorded word ranges for "Swapping this sum and this integral isn't automatic."
            for range in [(0, 8), (9, 4), (14, 3), (18, 3), (22, 4), (27, 8), (36, 5), (42, 10)] {
                started += scheduler.rangeWillBeSpoken(
                    utteranceIdentifier: 7, range: NSRange(location: range.0, length: range.1))
            }
            return started
        }
        #expect(replay() == ["s1", "s2", "s3"])
        #expect(replay() == replay())
    }
}

@Suite("Lifecycle registry (§4.2.2)")
struct LifecycleRegistryTests {
    @Test("transient marks fade at 4.0 s (D58), not before")
    func transientFade() {
        var registry = LifecycleRegistry()
        _ = registry.add(identifier: "ring", lifecycle: .transient, ink: .emphasis, now: 10)
        #expect(registry.nextTransientExpiry == 14)
        let result9 = registry.expireTransients(now: 13.99)
        #expect(result9.isEmpty)
        let result10 = registry.expireTransients(now: 14.0)
        #expect(result10 == ["ring"])
    }

    @Test("speech-bound marks fade when their group ends")
    func speechBoundFade() {
        var registry = LifecycleRegistry()
        _ = registry.add(
            identifier: "s1", lifecycle: .speechBound(group: "g1"), ink: .emphasis, now: 0)
        _ = registry.add(
            identifier: "s2", lifecycle: .speechBound(group: "g2"), ink: .emphasis, now: 0)
        let result11 = registry.groupFinished("g1")
        #expect(result11 == ["s1"])
        #expect(registry.liveIdentifiers == ["s2"])
    }

    @Test("the budget evicts the oldest emphasis mark past 3; pinned and board don't count")
    func budget() {
        var registry = LifecycleRegistry()
        _ = registry.add(identifier: "board", lifecycle: .board, ink: .emphasis, now: 0)
        for index in 1...3 {
            let result12 = registry.add(
                identifier: "s\(index)", lifecycle: .speechBound(group: nil), ink: .emphasis,
                now: Double(index))
            #expect(result12.isEmpty)
        }
        let result13 = registry.add(
            identifier: "s4", lifecycle: .speechBound(group: nil), ink: .emphasis, now: 4)
        #expect(result13 == ["s1"])
        let result14 = registry.add(
            identifier: "badge", lifecycle: .stepBound, ink: .stepBadge, now: 5)
        #expect(result14.isEmpty)
        #expect(Set(registry.liveIdentifiers) == ["board", "s2", "s3", "s4", "badge"])
    }

    @Test(
        "P-LEFTOVER: random scripts × random cancel points leave only pinned/board marks; budget always holds"
    )
    func noLeftoversProperty() {
        var random = SeededRandom(seed: 42)
        for _ in 0..<500 {
            var registry = LifecycleRegistry()
            var now: TimeInterval = 0
            let operationCount = Int(random.nextUnit() * 40) + 1
            let cancelAt = Int(random.nextUnit() * CGFloat(operationCount))
            for operation in 0..<operationCount {
                now += Double(random.nextUnit()) * 0.8
                if operation == cancelAt {
                    _ = registry.clearAllExceptPinnedAndBoard()
                    #expect(registry.isEmptyExceptPinnedAndBoard)
                    break
                }
                switch Int(random.nextUnit() * 6) {
                case 0, 1, 2:
                    let lifecycles: [MarkLifecycle] = [
                        .transient, .speechBound(group: "g1"), .speechBound(group: "g2"),
                        .stepBound, .board,
                    ]
                    let lifecycle = lifecycles[Int(random.nextUnit() * CGFloat(lifecycles.count))]
                    let ink: InkKind = random.nextUnit() < 0.15 ? .stepBadge : .emphasis
                    _ = registry.add(
                        identifier: "m\(operation)", lifecycle: lifecycle, ink: ink, now: now)
                case 3: _ = registry.expireTransients(now: now)
                case 4: _ = registry.groupFinished(random.nextUnit() < 0.5 ? "g1" : "g2")
                default:
                    _ = registry.clear(
                        identifiers: registry.liveIdentifiers.filter { _ in random.nextUnit() < 0.3
                        })
                }
                let liveEmphasis = registry.entries.filter {
                    $0.ink == .emphasis && !$0.lifecycle.isPinnedOrBoard
                }
                #expect(liveEmphasis.count <= LifecycleRegistry.maximumEmphasisMarks)
            }
            // The turn ends either way: the terminal state must hold the invariant (§4.2.2 rule 5).
            _ = registry.clearAllExceptPinnedAndBoard()
            #expect(registry.isEmptyExceptPinnedAndBoard)
        }
    }

    @Test("default lifecycles per primitive (§4.2.1)")
    func defaultLifecycles() {
        #expect(MarkLifecycle.forDrawing(shape: .ring, life: nil, group: "g1") == .transient)
        #expect(
            MarkLifecycle.forDrawing(shape: .ellipse, life: nil, group: "g1")
                == .speechBound(group: "g1"))
        #expect(MarkLifecycle.forDrawing(shape: .stepBadge, life: nil, group: nil) == .stepBound)
        #expect(
            MarkLifecycle.forDrawing(shape: .ellipse, life: "transient", group: "g1") == .transient)
    }
}

@Suite("Rough strokes (§5.5)")
struct RoughStrokeTests {
    @Test("the same seed draws the same paths; another seed draws different ones")
    func deterministicPerSeed() {
        let rect = CGRect(x: 100, y: 100, width: 120, height: 40)
        let first = RoughStrokeGenerator.ellipse(around: rect, seed: 7)
        let second = RoughStrokeGenerator.ellipse(around: rect, seed: 7)
        let other = RoughStrokeGenerator.ellipse(around: rect, seed: 8)
        #expect(first.strokes.count == 2)
        #expect(first.strokes[0] == second.strokes[0] && first.strokes[1] == second.strokes[1])
        #expect(first.strokes[0] != other.strokes[0])
        #expect(SeededRandom.seed(for: "s1") == SeededRandom.seed(for: "s1"))
    }

    @Test("an ellipse surrounds its target; an arrow has a head at its tip")
    func shapesSurroundTargets() {
        let rect = CGRect(x: 100, y: 100, width: 120, height: 40)
        #expect(
            RoughStrokeGenerator.ellipse(around: rect, seed: 1).strokes[0].boundingBoxOfPath
                .contains(rect))
        let arrow = RoughStrokeGenerator.arrow(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), seed: 1)
        #expect(arrow.accents.count == 1)
        #expect(arrow.accents[0].boundingBoxOfPath.maxX <= 200.5)
        #expect(RoughStrokeGenerator.highlight(over: rect, seed: 1).fill != nil)
    }
}

@Suite("Target resolution (§6.2, basic)")
struct TargetResolverTests {
    let space = ScreenSpace(
        displayFrameInAppKitGlobal: CGRect(x: 0, y: 0, width: 1512, height: 982),
        nativePixelSize: CGSize(width: 3024, height: 1964),
        modelPixelSize: CGSize(width: 1568, height: 1018))
    let marks = [
        Mark(
            id: 5, kind: .text, text: "Export", box: CGRect(x: 1000, y: 70, width: 150, height: 50))
    ]
    let snapTargets = [
        Mark(
            id: 1, kind: .text, text: "Export", box: CGRect(x: 1000, y: 70, width: 150, height: 50)),
        Mark(
            id: 2, kind: .text, text: "Export settings…",
            box: CGRect(x: 200, y: 900, width: 300, height: 40)),
        Mark(id: 3, kind: .shape, text: nil, box: CGRect(x: 2680, y: 70, width: 60, height: 60)),
        Mark(
            id: 4, kind: .text, text: "Layers", box: CGRect(x: 30, y: 170, width: 110, height: 40)),
    ]

    var resolver: TargetResolver {
        TargetResolver(
            screenSpace: space, marks: marks, snapTargets: snapTargets, cursorInNativePixels: nil)
    }

    @Test("mark ids only resolve against the capped marks the model saw")
    func markTargets() {
        #expect(resolver.resolve(.mark(id: 5))?.rectInNativePixels == marks[0].box)
        #expect(resolver.resolve(.mark(id: 3)) == nil)
    }

    @Test("text: exact beats a longer line; near disambiguates")
    func textTargets() {
        #expect(
            resolver.resolve(.text("export", near: nil, within: nil))?.rectInNativePixels
                == snapTargets[0].box)
        #expect(
            resolver.resolve(.text("Export settings", near: nil, within: nil))?.rectInNativePixels
                == snapTargets[1].box)
        #expect(resolver.resolve(.text("Nonexistent", near: nil, within: nil)) == nil)
    }

    @Test("a norm1000 point snaps to the smallest candidate under it")
    func pointSnaps() {
        // Centre of the gear shape at (2710, 100) native → model → norm1000.
        let model = space.nativePixelToModelPixel(CGPoint(x: 2710, y: 100))
        let norm = CGPoint(
            x: model.x / space.modelPixelSize.width * 1000,
            y: model.y / space.modelPixelSize.height * 1000)
        let resolved = resolver.resolve(.pixel(x: norm.x, y: norm.y, space: "norm1000"))
        #expect(resolved?.rectInNativePixels == snapTargets[2].box)
        #expect(resolved?.isLowConfidence == false)
        #expect(resolved?.source == .snappedPoint)
    }

    @Test("a point over nothing becomes a small low-confidence box")
    func unsnappedPoint() {
        let resolved = resolver.resolve(.pixel(x: 500, y: 500, space: "norm1000"))
        #expect(resolved?.isLowConfidence == true)
        #expect(resolved?.rectInNativePixels.width == 64)
    }

    @Test("regions and relative positions")
    func regionAndRelative() {
        let region = resolver.resolve(
            .region(NormalizedRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25), space: nil))
        #expect(abs((region?.rectInNativePixels.minX ?? 0) - 1512) < 1)
        let right = resolver.resolve(
            .relative(of: .text("Layers", near: nil, within: nil), position: .right, gap: 10))
        #expect(right?.rectInNativePixels.origin == CGPoint(x: 160, y: 190))
    }
}
