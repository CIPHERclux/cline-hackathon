import CoreGraphics
import Foundation

/// The coordinate spaces of one capture and the conversions between them (§6.3 "one
/// `ScreenSpace` transform object per capture"). Centralizes the v1 math that lived inline in
/// `CompanionManager` (pixel → point → AppKit global), so it is unit-tested once, including
/// negative-origin secondary displays, 1×/2× mixes and portrait displays.
///
/// Spaces:
/// - **native pixel**: the full-resolution capture of one display, top-left origin; local CV runs here.
/// - **model pixel**: the downscaled image the model sees (≤ 1568 px long edge), top-left origin.
/// - **norm1000**: 0–1000 across the model image on both axes, top-left origin (what
///   coordinate-answering models such as Gemini are trained on; used by `{"px":…,"space":"norm1000"}`).
/// - **display point**: points within the display, top-left origin.
/// - **AppKit global**: points, bottom-left origin, all displays (NSScreen / NSEvent space).
/// - **overlay local**: the per-display overlay window's SwiftUI space: points, top-left origin.
public struct ScreenSpace: Equatable, Sendable {
    /// The display's frame in AppKit global coordinates (`NSScreen.frame`).
    public var displayFrameInAppKitGlobal: CGRect
    /// Native capture size in pixels (display points × backing scale).
    public var nativePixelSize: CGSize
    /// Size of the downscaled image sent to the model.
    public var modelPixelSize: CGSize

    public init(displayFrameInAppKitGlobal: CGRect, nativePixelSize: CGSize, modelPixelSize: CGSize)
    {
        self.displayFrameInAppKitGlobal = displayFrameInAppKitGlobal
        self.nativePixelSize = nativePixelSize
        self.modelPixelSize = modelPixelSize
    }

    /// Native pixels per display point (2 on Retina).
    public var backingScale: CGFloat { nativePixelSize.width / displayFrameInAppKitGlobal.width }
    /// Model pixels per native pixel (≤ 1), per axis: the model image's sides are rounded
    /// separately, so one ratio would drift by up to half a point at the far edge.
    public var modelScaleX: CGFloat { modelPixelSize.width / nativePixelSize.width }
    public var modelScaleY: CGFloat { modelPixelSize.height / nativePixelSize.height }

    // MARK: Points

    public func nativePixelToModelPixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * modelScaleX, y: point.y * modelScaleY)
    }

    public func modelPixelToNativePixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / modelScaleX, y: point.y / modelScaleY)
    }

    /// 0–1000 on both axes of the model image → model pixels, clamped to the image.
    public func norm1000ToModelPixel(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1000) / 1000 * modelPixelSize.width,
            y: min(max(point.y, 0), 1000) / 1000 * modelPixelSize.height)
    }

    public func nativePixelToDisplayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / backingScale, y: point.y / backingScale)
    }

    public func displayPointToNativePixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * backingScale, y: point.y * backingScale)
    }

    /// Top-left display points → bottom-left AppKit global points.
    public func displayPointToAppKitGlobal(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: displayFrameInAppKitGlobal.origin.x + point.x,
            y: displayFrameInAppKitGlobal.origin.y + displayFrameInAppKitGlobal.height - point.y)
    }

    public func appKitGlobalToDisplayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - displayFrameInAppKitGlobal.origin.x,
            y: displayFrameInAppKitGlobal.origin.y + displayFrameInAppKitGlobal.height - point.y)
    }

    /// The overlay window covers exactly this display, so overlay-local == display points;
    /// this is `BlueCursorView.convertScreenPointToSwiftUICoordinates`.
    public func appKitGlobalToOverlayLocal(_ point: CGPoint) -> CGPoint {
        appKitGlobalToDisplayPoint(point)
    }

    /// What a model pixel answer becomes on screen: model pixel (clamped to the image) → native
    /// → display point → AppKit global. Identical to the v1 inline math (tested).
    public func modelPixelToAppKitGlobal(_ point: CGPoint) -> CGPoint {
        let clamped = CGPoint(
            x: min(max(point.x, 0), modelPixelSize.width),
            y: min(max(point.y, 0), modelPixelSize.height))
        return displayPointToAppKitGlobal(
            nativePixelToDisplayPoint(modelPixelToNativePixel(clamped)))
    }

    // MARK: Rects

    public func nativePixelRectToDisplayPoints(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x / backingScale, y: rect.origin.y / backingScale,
            width: rect.width / backingScale, height: rect.height / backingScale)
    }

    public func displayPointRectToNativePixels(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * backingScale, y: rect.origin.y * backingScale,
            width: rect.width * backingScale, height: rect.height * backingScale)
    }

    public func nativePixelRectToModelPixels(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * modelScaleX, y: rect.origin.y * modelScaleY,
            width: rect.width * modelScaleX, height: rect.height * modelScaleY)
    }

    /// The model image size for a display, keeping its aspect ratio (§6.2 a: ≤ 1568 px long edge).
    public static func modelPixelSize(
        forNativePixelSize nativeSize: CGSize, longEdge: CGFloat = 1568
    ) -> CGSize {
        let scale = min(1, longEdge / max(nativeSize.width, nativeSize.height))
        return CGSize(
            width: (nativeSize.width * scale).rounded(),
            height: (nativeSize.height * scale).rounded())
    }
}
