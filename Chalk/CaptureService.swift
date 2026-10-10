//
//  CaptureService.swift
//  Chalk
//
//  §6.2 (a) capture & normalize: the cursor's display at native pixels (for local CV), the
//  downscaled ≤ 1568 px JPEG the model sees, one ScreenSpace for the conversions, the frontmost
//  window's frame (marks inside it win, §6.2 b), and the cursor position. Our own windows are
//  excluded. Nothing is written to disk (§10.1).
//

import AppKit
import Carbon.HIToolbox
import ChalkCore
import ScreenCaptureKit

struct ScreenCaptureResult {
    let nativeImage: CGImage
    let modelJPEGData: Data
    let screenSpace: ScreenSpace
    /// The frontmost app's front window, in native pixels of this capture.
    let frontmostWindowRectInNativePixels: CGRect?
    /// The cursor at key-down, in native pixels of this capture.
    let cursorInNativePixels: CGPoint?
}

enum CaptureServiceError: LocalizedError {
    case secureInputActive
    case noDisplay
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .secureInputActive: return "a password field is focused"
        case .noDisplay: return "no display available for capture"
        case .encodingFailed: return "could not encode the screenshot"
        }
    }
}

@MainActor
enum CaptureService {
    static func captureCursorDisplay() async throws -> ScreenCaptureResult {
        // §10.2 secure input pause: never look while the learner types a password.
        guard !IsSecureEventInputEnabled() else { throw CaptureServiceError.secureInputActive }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw CaptureServiceError.noDisplay }

        let mouseLocation = NSEvent.mouseLocation
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // SCDisplay.frame is Core Graphics space (top-left origin); the mouse and NSScreen are
        // AppKit space (bottom-left), so displays are matched through NSScreenNumber.
        var screenByDisplayIdentifier: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            {
                screenByDisplayIdentifier[number] = screen
            }
        }
        func appKitFrame(of display: SCDisplay) -> CGRect {
            screenByDisplayIdentifier[display.displayID]?.frame
                ?? CGRect(
                    x: display.frame.origin.x, y: display.frame.origin.y,
                    width: CGFloat(display.width),
                    height: CGFloat(display.height))
        }
        let display =
            content.displays.first { appKitFrame(of: $0).contains(mouseLocation) }
            ?? content.displays[0]
        let displayFrame = appKitFrame(of: display)
        let backingScale = screenByDisplayIdentifier[display.displayID]?.backingScaleFactor ?? 2

        // §6.3 "all local CV runs on native pixels".
        let configuration = SCStreamConfiguration()
        configuration.width = Int(displayFrame.width * backingScale)
        configuration.height = Int(displayFrame.height * backingScale)
        configuration.showsCursor = false
        let nativeImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: ownAppWindows),
            configuration: configuration)

        let nativeSize = CGSize(width: nativeImage.width, height: nativeImage.height)
        let screenSpace = ScreenSpace(
            displayFrameInAppKitGlobal: displayFrame, nativePixelSize: nativeSize,
            modelPixelSize: ScreenSpace.modelPixelSize(forNativePixelSize: nativeSize))
        guard
            let modelImage = MarksImageRenderer.modelImage(
                from: nativeImage, screenSpace: screenSpace),
            let modelJPEGData = MarksImageRenderer.jpegData(modelImage)
        else { throw CaptureServiceError.encodingFailed }

        let cursorDisplayPoint = screenSpace.appKitGlobalToDisplayPoint(mouseLocation)
        return ScreenCaptureResult(
            nativeImage: nativeImage, modelJPEGData: modelJPEGData, screenSpace: screenSpace,
            frontmostWindowRectInNativePixels: frontmostWindowRect(
                onDisplayWithCoreGraphicsFrame: display.frame, screenSpace: screenSpace),
            cursorInNativePixels: displayFrame.contains(mouseLocation)
                ? screenSpace.displayPointToNativePixel(cursorDisplayPoint) : nil)
    }

    /// §6.2 (f) verification: a fresh native-resolution crop of part of the display a capture was
    /// taken on. Our windows are excluded, so drawn marks never hide the text being re-read.
    static func captureRegion(nativePixelRect: CGRect, screenSpace: ScreenSpace) async throws
        -> CGImage
    {
        guard !IsSecureEventInputEnabled() else { throw CaptureServiceError.secureInputActive }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        guard
            let screen = NSScreen.screens.first(where: {
                $0.frame == screenSpace.displayFrameInAppKitGlobal
            }),
            let displayIdentifier =
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
            let display = content.displays.first(where: { $0.displayID == displayIdentifier })
        else { throw CaptureServiceError.noDisplay }
        let configuration = SCStreamConfiguration()
        // sourceRect is in the display's points, top-left origin.
        configuration.sourceRect = screenSpace.nativePixelRectToDisplayPoints(nativePixelRect)
        configuration.width = Int(nativePixelRect.width)
        configuration.height = Int(nativePixelRect.height)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: ownAppWindows),
            configuration: configuration)
    }

    /// The frontmost app's front window. CGWindowList is ordered front to back, which
    /// SCShareableContent doesn't promise.
    private static func frontmostWindowRect(
        onDisplayWithCoreGraphicsFrame displayCoreGraphicsFrame: CGRect, screenSpace: ScreenSpace
    )
        -> CGRect?
    {
        guard
            let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?
                .processIdentifier,
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in windowList {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == frontmostProcessIdentifier,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.intersects(displayCoreGraphicsFrame)
            else { continue }
            // Core Graphics global points (top-left) → this display's points → native pixels.
            let displayLocal = bounds.offsetBy(
                dx: -displayCoreGraphicsFrame.minX, dy: -displayCoreGraphicsFrame.minY)
            let scale = screenSpace.backingScale
            return CGRect(
                x: displayLocal.minX * scale, y: displayLocal.minY * scale,
                width: displayLocal.width * scale, height: displayLocal.height * scale)
        }
        return nil
    }
}
