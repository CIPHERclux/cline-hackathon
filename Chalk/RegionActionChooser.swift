//
//  RegionActionChooser.swift
//  Chalk
//
//  §4.2.5 / §4.3: a lasso released without speaking shows three chips next to the region:
//  Explain, Summarise, Translate. Picking one asks about the region; ignoring it for a few
//  seconds lets it go (nothing is sent). A small non-activating panel, so the user's app keeps
//  focus, and it only exists while the user is choosing.
//

import AppKit
import ChalkCore
import SwiftUI

@MainActor
final class RegionActionChooser {
    static let panelSize = CGSize(width: 290, height: 44)
    /// Untouched for this long, the chooser leaves and nothing is asked.
    static let dismissAfterSeconds = 8.0

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var onPick: ((RegionAction) -> Void)?

    var isShowing: Bool { panel?.isVisible ?? false }

    /// `regionInDisplayPoints` is top-left display points on the display at `displayFrame`.
    func show(
        nextTo regionInDisplayPoints: CGRect, displayFrame: CGRect,
        onPick: @escaping (RegionAction) -> Void
    ) {
        self.onPick = onPick
        let panel = self.panel ?? makePanel()
        // Below the region, or above it when it sits near the bottom of the display.
        let regionGlobal = CGRect(
            x: displayFrame.minX + regionInDisplayPoints.minX,
            y: displayFrame.maxY - regionInDisplayPoints.maxY,
            width: regionInDisplayPoints.width, height: regionInDisplayPoints.height)
        var origin = CGPoint(
            x: regionGlobal.midX - Self.panelSize.width / 2,
            y: regionGlobal.minY - Self.panelSize.height - 10)
        if origin.y < displayFrame.minY + 10 { origin.y = regionGlobal.maxY + 10 }
        origin.x = min(
            max(origin.x, displayFrame.minX + 10), displayFrame.maxX - Self.panelSize.width - 10)
        panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
        panel.sharingType = ChalkOverlaySharing.current
        panel.orderFrontRegardless()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dismissAfterSeconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        onPick = nil
        panel?.orderOut(nil)
    }

    private func pick(_ action: RegionAction) {
        let onPick = self.onPick
        dismiss()
        onPick?(action)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstClickHostingView(
            rootView: RegionActionChooserView(onPick: { [weak self] in self?.pick($0) }))
        self.panel = panel
        return panel
    }
}

private struct RegionActionChooserView: View {
    let onPick: (RegionAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RegionAction.allCases, id: \.self) { action in
                Button(action: { onPick(action) }) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(
                            action == .explain ? DS.Colors.textOnAccent : DS.Colors.textPrimary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    action == .explain
                                        ? DS.Colors.accent : DS.Colors.surface2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(6)
        .frame(
            width: RegionActionChooser.panelSize.width, height: RegionActionChooser.panelSize.height
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.background.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        )
    }
}
