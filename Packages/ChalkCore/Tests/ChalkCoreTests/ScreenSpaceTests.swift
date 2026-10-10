import CoreGraphics
import Testing

@testable import ChalkCore

/// The v1 inline math from `CompanionManager` (before S04), kept verbatim as the reference.
func version1ScreenshotPointToAppKitGlobal(
    _ point: CGPoint, screenshotWidth: CGFloat, screenshotHeight: CGFloat, displayFrame: CGRect
) -> CGPoint {
    let clampedX = max(0, min(point.x, screenshotWidth))
    let clampedY = max(0, min(point.y, screenshotHeight))
    let displayLocalX = clampedX * (displayFrame.width / screenshotWidth)
    let displayLocalY = clampedY * (displayFrame.height / screenshotHeight)
    let appKitY = displayFrame.height - displayLocalY
    return CGPoint(x: displayLocalX + displayFrame.origin.x, y: appKitY + displayFrame.origin.y)
}

func isClose(_ first: CGPoint, _ second: CGPoint, tolerance: CGFloat = 0.01) -> Bool {
    abs(first.x - second.x) <= tolerance && abs(first.y - second.y) <= tolerance
}

@Suite("ScreenSpace (§6.3)")
struct ScreenSpaceTests {
    /// Built-in Retina laptop at the origin, a 1× external to the left with a negative origin,
    /// and a portrait 2× display above.
    static let displays: [(name: String, frame: CGRect, scale: CGFloat)] = [
        ("built-in 2×", CGRect(x: 0, y: 0, width: 1512, height: 982), 2),
        ("external 1×, negative origin", CGRect(x: -1920, y: 200, width: 1920, height: 1080), 1),
        ("portrait 2× above", CGRect(x: 300, y: 982, width: 1080, height: 1920), 2),
    ]

    static func space(for display: (name: String, frame: CGRect, scale: CGFloat)) -> ScreenSpace {
        let native = CGSize(
            width: display.frame.width * display.scale, height: display.frame.height * display.scale
        )
        return ScreenSpace(
            displayFrameInAppKitGlobal: display.frame, nativePixelSize: native,
            modelPixelSize: ScreenSpace.modelPixelSize(forNativePixelSize: native))
    }

    @Test("model pixel → AppKit global reproduces the v1 math on every display")
    func characterizationMatchesVersion1() {
        for display in Self.displays {
            let space = Self.space(for: display)
            for point in [
                CGPoint(x: 0, y: 0), CGPoint(x: 100.5, y: 42),
                CGPoint(x: space.modelPixelSize.width, y: space.modelPixelSize.height),
                CGPoint(x: -20, y: 99_999),
            ] {
                let expected = version1ScreenshotPointToAppKitGlobal(
                    point, screenshotWidth: space.modelPixelSize.width,
                    screenshotHeight: space.modelPixelSize.height,
                    displayFrame: display.frame)
                #expect(
                    isClose(space.modelPixelToAppKitGlobal(point), expected),
                    "\(display.name) \(point)")
            }
        }
    }

    @Test("round trips: native ↔ model, display point ↔ AppKit global ↔ overlay local")
    func roundTrips() {
        for display in Self.displays {
            let space = Self.space(for: display)
            let native = CGPoint(x: 777, y: 333)
            #expect(
                isClose(
                    space.modelPixelToNativePixel(space.nativePixelToModelPixel(native)), native),
                "\(display.name)")
            let displayPoint = CGPoint(x: 400, y: 120)
            let global = space.displayPointToAppKitGlobal(displayPoint)
            #expect(
                isClose(space.appKitGlobalToDisplayPoint(global), displayPoint), "\(display.name)")
            #expect(
                isClose(space.appKitGlobalToOverlayLocal(global), displayPoint), "\(display.name)")
            #expect(display.frame.contains(global), "\(display.name) \(global)")
        }
    }

    @Test("top-left of the display maps to the top-left corner in AppKit space")
    func cornersLandOnTheRightDisplay() {
        let external = Self.space(for: Self.displays[1])
        #expect(isClose(external.displayPointToAppKitGlobal(.zero), CGPoint(x: -1920, y: 1280)))
        let portrait = Self.space(for: Self.displays[2])
        #expect(isClose(portrait.modelPixelToAppKitGlobal(.zero), CGPoint(x: 300, y: 2902)))
    }

    @Test("model image keeps the aspect ratio within 1568 px")
    func modelImageSize() {
        #expect(
            ScreenSpace.modelPixelSize(forNativePixelSize: CGSize(width: 3024, height: 1964))
                == CGSize(width: 1568, height: 1018))
        #expect(
            ScreenSpace.modelPixelSize(forNativePixelSize: CGSize(width: 2160, height: 3840))
                == CGSize(width: 882, height: 1568))
        #expect(
            ScreenSpace.modelPixelSize(forNativePixelSize: CGSize(width: 1280, height: 800))
                == CGSize(width: 1280, height: 800))
    }

    @Test("norm1000 covers the model image and clamps")
    func norm1000() {
        let space = Self.space(for: Self.displays[0])
        #expect(
            isClose(
                space.norm1000ToModelPixel(CGPoint(x: 500, y: 500)),
                CGPoint(x: space.modelPixelSize.width / 2, y: space.modelPixelSize.height / 2)))
        #expect(
            isClose(
                space.norm1000ToModelPixel(CGPoint(x: 1200, y: -5)),
                CGPoint(x: space.modelPixelSize.width, y: 0)))
    }

    @Test("native pixel rects become display points on Retina")
    func rectConversion() {
        let space = Self.space(for: Self.displays[0])
        #expect(
            space.nativePixelRectToDisplayPoints(CGRect(x: 100, y: 50, width: 40, height: 20))
                == CGRect(x: 50, y: 25, width: 20, height: 10))
    }
}
