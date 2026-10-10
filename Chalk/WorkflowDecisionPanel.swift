import AppKit
import ChalkCore
import SwiftUI

@MainActor
final class WorkflowDecisionPanel {
    private var panel: NSPanel?

    func show(
        _ decision: AdaptiveDecision, onAnswer: @escaping (String) -> Void,
        onStop: @escaping () -> Void
    ) {
        hide()
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 230),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = ChalkOverlaySharing.current
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = FirstClickHostingView(
            rootView: WorkflowDecisionView(decision: decision, onAnswer: onAnswer, onStop: onStop))
        panel.contentView = view
        let height = max(view.fittingSize.height, 160)
        let screen =
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(
            CGRect(
                x: visible.midX - 220, y: visible.maxY - height - 150, width: 440, height: height),
            display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }
}

private struct WorkflowDecisionView: View {
    let decision: AdaptiveDecision
    let onAnswer: (String) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ChalkBrandMark(size: 30)
                ChalkSectionLabel(title: "Your choice")
                Spacer()
                Button("Stop", action: onStop).buttonStyle(.plain).pointerCursor()
            }
            Text(decision.question).font(.system(size: 19, weight: .medium, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(decision.options.enumerated()), id: \.offset) { index, option in
                Button {
                    onAnswer(option)
                } label: {
                    HStack {
                        Text("\(index + 1)").font(.system(size: 11, design: .monospaced))
                        Text(option).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(10)
                    .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Text("Click a choice or hold ⌃⌥ and say its name or number.")
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(18).frame(width: 440)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(DS.Colors.borderSubtle))
        .environment(\.colorScheme, .light)
    }
}
