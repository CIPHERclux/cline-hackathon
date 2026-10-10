//
//  GuideCards.swift
//  Chalk
//
//  The two small windows of a guided walkthrough (§4.2.6, §5.11 "Walkthrough step"):
//  - the step HUD: "Step 2 of 7 · instruction", the shortcut, and Back / Skip / Stop;
//  - the recap card at the end: the steps with their shortcuts, copyable (§4.2.6 step 9).
//  Both are non-activating panels, so clicking them never takes focus from the user's app, and
//  they follow the presenter-mode sharing policy like the overlays (§6.6).
//

import AppKit
import ChalkCore
import Combine
import SwiftUI

// MARK: - Step HUD

@MainActor
final class WalkthroughHUDModel: ObservableObject {
    @Published var progressText = ""
    @Published var instruction = ""
    @Published var shortcutSymbols: String?
    @Published var statusText: String?
    @Published var canGoBack = false
}

@MainActor
final class WalkthroughHUDPanel {
    static let panelSize = CGSize(width: 520, height: 96)
    /// Gap from the top or bottom of the visible frame.
    static let edgeInsetPoints: CGFloat = 36

    let model = WalkthroughHUDModel()
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    var onStop: (() -> Void)?

    private var panel: NSPanel?

    func show(onDisplay displayFrame: CGRect?, avoiding targetRectInAppKitGlobal: CGRect?) {
        let panel = self.panel ?? makePanel()
        let screen =
            NSScreen.screens.first { displayFrame.map($0.frame.intersects) ?? false }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let width = Self.panelSize.width
        let topOrigin = CGPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - Self.panelSize.height - Self.edgeInsetPoints)
        let bottomOrigin = CGPoint(
            x: visibleFrame.midX - width / 2, y: visibleFrame.minY + Self.edgeInsetPoints)
        // Top of the screen by default; the bottom when the step's control is up there (the HUD
        // must never cover what it asks the user to click).
        var origin = topOrigin
        if let targetRectInAppKitGlobal,
            CGRect(origin: topOrigin, size: Self.panelSize).insetBy(dx: -20, dy: -20)
                .intersects(targetRectInAppKitGlobal)
        {
            origin = bottomOrigin
        }
        panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
        panel.sharingType = ChalkOverlaySharing.current
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstClickHostingView(
            rootView: WalkthroughHUDView(
                model: model,
                onBack: { [weak self] in self?.onBack?() },
                onSkip: { [weak self] in self?.onSkip?() },
                onStop: { [weak self] in self?.onStop?() }))
        self.panel = panel
        return panel
    }
}

private struct WalkthroughHUDView: View {
    @ObservedObject var model: WalkthroughHUDModel
    let onBack: () -> Void
    let onSkip: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ChalkBrandMark(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.progressText.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                    if let statusText = model.statusText {
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(DS.Colors.warning)
                    }
                }
                Text(model.instruction)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let shortcutSymbols = model.shortcutSymbols {
                    Text(shortcutSymbols)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(DS.Colors.surface2))
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                hudButton("Back", action: onBack).disabled(!model.canGoBack)
                    .opacity(model.canGoBack ? 1 : 0.4)
                hudButton("Skip", action: onSkip)
                hudButton("Stop", action: onStop)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(
            width: WalkthroughHUDPanel.panelSize.width,
            height: WalkthroughHUDPanel.panelSize.height
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.background.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        )
    }

    private func hudButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Recap card

@MainActor
final class WalkthroughRecapModel: ObservableObject {
    @Published var title = ""
    @Published var appName: String?
    @Published var steps: [WalkthroughStep] = []
    @Published var wasSaved = false
    @Published var didCopy = false
}

@MainActor
final class WalkthroughRecapPanel {
    static let panelWidth: CGFloat = 400

    let model = WalkthroughRecapModel()
    private var panel: NSPanel?

    func show(
        title: String, appName: String?, steps: [WalkthroughStep], wasSaved: Bool,
        onDisplay displayFrame: CGRect?
    ) {
        model.title = title
        model.appName = appName
        model.steps = steps
        model.wasSaved = wasSaved
        model.didCopy = false
        let panel = self.panel ?? makePanel()
        let height = min(560, 120 + CGFloat(steps.count) * 30)
        let screen =
            NSScreen.screens.first { displayFrame.map($0.frame.intersects) ?? false }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        panel.setFrame(
            CGRect(
                x: visibleFrame.maxX - Self.panelWidth - 40,
                y: visibleFrame.midY - height / 2, width: Self.panelWidth, height: height),
            display: true)
        panel.sharingType = ChalkOverlaySharing.current
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstClickHostingView(
            rootView: WalkthroughRecapView(
                model: model,
                onCopy: { [weak self] in self?.copyRecap() },
                onClose: { [weak self] in self?.hide() }))
        self.panel = panel
        return panel
    }

    private func copyRecap() {
        let text = WalkthroughSession.recapText(
            title: model.title, appName: model.appName, steps: model.steps)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.didCopy = true
    }
}

private struct WalkthroughRecapView: View {
    @ObservedObject var model: WalkthroughRecapModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DONE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#34D399"))
                    Text(model.title)
                        .font(.system(size: 20, weight: .medium, design: .serif))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    if let appName = model.appName {
                        Text(appName)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(width: 16, alignment: .trailing)
                            Text(step.instruction)
                                .font(.system(size: 12.5))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if let symbols = step.shortcut.flatMap(KeyboardShortcut.init(parsing:))?
                                .symbols
                            {
                                Text(symbols)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(DS.Colors.surface2))
                            }
                        }
                    }
                }
            }
            HStack {
                Text(model.wasSaved ? "Saved to your how-tos" : "")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button(action: onCopy) {
                    Text(model.didCopy ? "Copied" : "Copy steps")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.background.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        )
    }
}
