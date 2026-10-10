import AppKit
import Combine
import SwiftUI

/// Opt-in live OSLog reader. No polling, capture, model calls or disk export (§6.5, §10.1).
@MainActor
final class LiveLogsModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var status = "Stopped"
    private var buffer = LiveLogBuffer()
    private var process: Process?
    private var output: Pipe?
    private var generation = 0

    func start() {
        guard process == nil else { return }
        generation += 1
        let currentGeneration = generation
        let reader = Process()
        let pipe = Pipe()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        reader.arguments = [
            "stream", "--style", "compact", "--level", "debug", "--color", "none",
            "--predicate", "subsystem == 'com.chalk.app'",
        ]
        reader.standardOutput = pipe
        reader.standardError = pipe
        reader.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.buffer.append(data)
                self.lines = self.buffer.lines
            }
        }
        reader.terminationHandler = { [weak self] terminated in
            let exitStatus = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.output = nil
                self.isStreaming = false
                self.status = "Log reader exited (\(exitStatus)). Resume to retry."
            }
        }
        do {
            try reader.run()
            process = reader
            output = pipe
            isStreaming = true
            status = "Live · current events only · latest \(LiveLogBuffer.maximumEntries) lines"
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            status = "Cannot start log reader: \(error.localizedDescription)"
            buffer.appendLine(status)
            lines = buffer.lines
        }
    }

    func stop() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        output = nil
        isStreaming = false
        status = "Paused · events while paused are not collected"
    }

    func clear() {
        buffer.clear()
        lines = []
    }
}

@MainActor
final class LiveLogsWindowController: NSObject, NSWindowDelegate {
    private let model = LiveLogsModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let logWindow = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 940, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            logWindow.title = "Chalk · Live Logs"
            logWindow.minSize = CGSize(width: 660, height: 360)
            logWindow.isReleasedWhenClosed = false
            logWindow.delegate = self
            // Debug content must not appear in captures sent to models or screen shares.
            logWindow.sharingType = .none
            logWindow.contentView = NSHostingView(rootView: LiveLogsView(model: model))
            logWindow.center()
            window = logWindow
        }
        model.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
    func stop() { model.stop() }
}

private struct LiveLogsView: View {
    @ObservedObject var model: LiveLogsModel
    @State private var filter = ""
    @State private var followsLatest = true

    private var visibleLines: [String] {
        filter.isEmpty
            ? model.lines : model.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ChalkBrandMark(size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live logs").font(.system(size: 23, weight: .medium, design: .serif))
                    Text(model.status).font(.system(size: 11)).foregroundStyle(
                        DS.Colors.textSecondary)
                }
                Spacer()
                Button(model.isStreaming ? "Pause" : "Resume") {
                    if model.isStreaming { model.stop() } else { model.start() }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        visibleLines.joined(separator: "\n"), forType: .string)
                }
                .disabled(visibleLines.isEmpty)
                Button("Clear") { model.clear() }
            }
            HStack {
                TextField("Filter: walkthrough, dispatch, whiteboard, engine…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Follow latest", isOn: $followsLatest).toggleStyle(.checkbox)
            }
            ScrollViewReader { scroll in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            visibleLines.isEmpty
                                ? "Waiting for matching runtime events…"
                                : visibleLines.joined(separator: "\n")
                        )
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        Color.clear.frame(width: 1, height: 1).id("latest")
                    }
                    .padding(14)
                }
                .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderSubtle))
                .onChange(of: model.lines) { _, _ in
                    if followsLatest { scroll.scrollTo("latest", anchor: .bottom) }
                }
            }
            Text(
                "Session-only diagnostics. Existing workflow logs may name controls or instructions. Credentials, image payloads and accounting events are omitted. Copy only if you want to share these details."
            )
            .font(.system(size: 11))
            .foregroundStyle(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.background)
        .environment(\.colorScheme, .light)
        .tint(DS.Colors.accent)
    }
}
