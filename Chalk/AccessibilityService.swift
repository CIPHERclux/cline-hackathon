//
//  AccessibilityService.swift
//  Chalk
//
//  Reads the front app's accessibility tree (D74, owner-approved): the exact frame, role, name
//  and value of every button and field, which one has focus, and when that changes. Walkthroughs
//  find controls and notice "done" with it in milliseconds, without a screenshot or a model;
//  answers snap their circles to real controls. Only the front app, only while the user has
//  started a turn or a walkthrough (§10.8: never in the background, never logged).
//
//  Heavy apps answer slowly (bounded accessibility reads), so every read runs off the main thread
//  with a per-call messaging timeout and a node and time budget, and returns what it has.
//

import AppKit
import ApplicationServices
import ChalkCore

enum AccessibilityService {
    /// Every element read costs a round trip to the app; past these the snapshot stops.
    static let maximumNodeCount = 2500
    static let timeBudgetSeconds = 0.35
    /// A single unanswered call gives up after this (the app is busy).
    static let messagingTimeoutSeconds: Float = 0.2

    /// Chromium and Electron only build their page tree for assistive apps that ask for it.
    static let chromiumBundlePrefixes = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser",
        "com.vivaldi", "com.operasoftware",
    ]

    /// The front app's tree, or nil without permission or a front app (Chalk's own windows
    /// don't count).
    static func snapshotOfFrontmostApp() async -> AccessibilitySnapshot? {
        // Spotlight is system-owned and often leaves NSWorkspace's front app unchanged.
        // These reads are still only called within a user-started turn/walkthrough (§10.8).
        // Its panel on screen means it is what the user is looking at, even when its focus
        // can't be read (⌘Space steps finished only on a readable focus and stalled, D86).
        if let spotlight = await snapshotOfSpotlight() {
            return spotlight
        }
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        let processIdentifier = application.processIdentifier
        let appName = application.localizedName
        let bundleIdentifier = application.bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            readSnapshot(
                processIdentifier: processIdentifier, appName: appName,
                bundleIdentifier: bundleIdentifier)
        }.value
    }

    /// The Dock's items (D76): "click Chrome in the Dock" is found exactly, not by a model look.
    static func snapshotOfSpotlight() async -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted(),
            let spotlight = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.Spotlight"
            ).first
        else { return nil }
        let processIdentifier = spotlight.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            // A running process is not proof of an open panel; only inspect on-screen windows.
            let windows =
                CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            guard
                windows.contains(where: { window in
                    guard
                        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                            == processIdentifier,
                        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                        let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 100,
                        rect.height > 20
                    else { return false }
                    return (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
                })
            else { return nil }
            return readSnapshot(
                processIdentifier: processIdentifier, appName: "Spotlight",
                bundleIdentifier: "com.apple.Spotlight")
        }.value
    }

    /// The Dock's items are read only during user-started guidance.
    static func snapshotOfDock() async -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted(),
            let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first
        else { return nil }
        let processIdentifier = dock.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            readSnapshot(
                processIdentifier: processIdentifier, appName: "Dock",
                bundleIdentifier: "com.apple.dock")
        }.value
    }

    private static func readSnapshot(
        processIdentifier: pid_t, appName: String?, bundleIdentifier: String?
    ) -> AccessibilitySnapshot {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)
        enableWebContentIfNeeded(appElement, bundleIdentifier: bundleIdentifier)

        let focusedElement: AXUIElement? = attribute(appElement, kAXFocusedUIElementAttribute)
        let focusedWindow: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute)
        let windowTitle: String? = focusedWindow.flatMap { attribute($0, kAXTitleAttribute) }
        var documentURL: String? = focusedWindow.flatMap { attribute($0, kAXDocumentAttribute) }

        var nodes: [AccessibilityNode] = []
        let startedAt = Date()
        // The menu bar's items (and any open menu) first, then the focused window.
        var queue: [AXUIElement] = []
        // System panels may expose focus without a conventional focused window.
        if let focusedElement { queue.append(focusedElement) }
        if let menuBar: AXUIElement = attribute(appElement, kAXMenuBarAttribute) {
            queue.append(menuBar)
        }
        if let focusedWindow {
            queue.append(focusedWindow)
        } else if let children: [AXUIElement] = attribute(appElement, kAXChildrenAttribute) {
            // No window (the Dock, a menu-bar app): its top-level elements.
            queue.append(contentsOf: children)
        }
        var queueIndex = 0
        while queueIndex < queue.count, nodes.count < maximumNodeCount,
            Date().timeIntervalSince(startedAt) < timeBudgetSeconds
        {
            let element = queue[queueIndex]
            queueIndex += 1
            let attributeNames =
                [
                    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                    kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute,
                    kAXPositionAttribute, kAXSizeAttribute, kAXSelectedAttribute,
                    kAXEnabledAttribute, kAXChildrenAttribute,
                ] as CFArray
            var valuesReference: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(
                    element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0),
                    &valuesReference) == .success,
                let values = valuesReference as? [AnyObject], values.count == 11
            else { continue }
            let role = values[0] as? String ?? ""
            if role == "AXWebArea", documentURL == nil,
                let url: URL = attribute(element, "AXURL" as String)
            {
                documentURL = url.absoluteString
            }
            if let children = values[10] as? [AXUIElement] {
                // Closed menus have children too; skip them unless the menu is open (it has a
                // frame), so the closed menu bar doesn't fill the budget.
                if role != "AXMenu" || frame(position: values[6], size: values[7]).width > 0 {
                    queue.append(contentsOf: children)
                }
            }
            let elementFrame = frame(position: values[6], size: values[7])
            guard elementFrame.width > 0, elementFrame.height > 0 else { continue }
            nodes.append(
                AccessibilityNode(
                    role: role, subrole: values[1] as? String, title: values[2] as? String,
                    label: values[3] as? String, value: stringValue(values[4]),
                    placeholder: values[5] as? String, frame: elementFrame,
                    isFocused: focusedElement.map { CFEqual($0, element) } ?? false,
                    isSelected: (values[8] as? Bool) ?? false,
                    isEnabled: (values[9] as? Bool) ?? true))
        }
        return AccessibilitySnapshot(
            appName: appName, bundleIdentifier: bundleIdentifier, focusedWindowTitle: windowTitle,
            documentURL: documentURL, nodes: nodes)
    }

    /// Asks Chromium and Electron apps to expose their page tree (each app only once).
    private static let webEnabledProcesses = OSAllocatedSet()

    private static func enableWebContentIfNeeded(
        _ appElement: AXUIElement, bundleIdentifier: String?
    ) {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(appElement, &processIdentifier)
        guard webEnabledProcesses.insert(processIdentifier) else { return }
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleIdentifier, chromiumBundlePrefixes.contains(where: bundleIdentifier.hasPrefix)
        {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Change notifications

    /// Watches the front app for focus, value, window, title, selection and menu changes while a
    /// walkthrough step waits; `onChange` runs on the main thread. Stop it with `stop()`.
    final class ChangeObserver {
        private var observer: AXObserver?
        private var runLoopSource: CFRunLoopSource?
        private let onChange: () -> Void

        static let notifications = [
            kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
            kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification,
            kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXUIElementDestroyedNotification,
            "AXLoadComplete",
        ]

        init?(processIdentifier: pid_t, onChange: @escaping () -> Void) {
            self.onChange = onChange
            var createdObserver: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                let changeObserver = Unmanaged<ChangeObserver>.fromOpaque(context)
                    .takeUnretainedValue()
                DispatchQueue.main.async { changeObserver.onChange() }
            }
            guard AXObserverCreate(processIdentifier, callback, &createdObserver) == .success,
                let createdObserver
            else { return nil }
            observer = createdObserver
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in Self.notifications {
                AXObserverAddNotification(
                    createdObserver, appElement, notification as CFString, context)
            }
            let source = AXObserverGetRunLoopSource(createdObserver)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        func stop() {
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            }
            runLoopSource = nil
            observer = nil
        }

        deinit { stop() }
    }

    // MARK: - Helpers

    private static func attribute<Value>(_ element: AXUIElement, _ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value
        else { return nil }
        return value as? Value
    }

    private static func frame(position: AnyObject, size: AnyObject) -> CGRect {
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return .zero }
        // swiftlint-free force casts: both IDs were checked above.
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func stringValue(_ value: AnyObject) -> String? {
        if let string = value as? String { return String(string.prefix(300)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// A tiny thread-safe set of process ids.
private final class OSAllocatedSet: @unchecked Sendable {
    private var values = Set<pid_t>()
    private let lock = NSLock()

    /// Returns true when the value was new.
    func insert(_ value: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.insert(value).inserted
    }
}

extension ScreenSpace {
    /// An accessibility frame (global points, top-left of the main display) in this capture's
    /// native pixels. `mainDisplayHeight` is the main screen's height in points.
    func accessibilityRectToNativePixels(_ rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        let display = displayFrameInAppKitGlobal
        // AppKit global y of the rect's top edge is mainDisplayHeight − rect.minY.
        let topInDisplay = display.maxY - (mainDisplayHeight - rect.minY)
        let displayRect = CGRect(
            x: rect.minX - display.minX, y: topInDisplay, width: rect.width, height: rect.height)
        return displayPointRectToNativePixels(displayRect)
    }

    /// The inverse: native pixels of this capture → accessibility (global top-left) points.
    func nativePixelsToAccessibilityRect(_ rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        let display = displayFrameInAppKitGlobal
        let displayRect = nativePixelRectToDisplayPoints(rect)
        return CGRect(
            x: displayRect.minX + display.minX,
            y: mainDisplayHeight - display.maxY + displayRect.minY, width: displayRect.width,
            height: displayRect.height)
    }

    /// The display's area in accessibility coordinates, to skip elements on other displays.
    func accessibilityVisibleArea(mainDisplayHeight: CGFloat) -> CGRect {
        let display = displayFrameInAppKitGlobal
        return CGRect(
            x: display.minX, y: mainDisplayHeight - display.maxY, width: display.width,
            height: display.height)
    }
}
