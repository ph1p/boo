import Cocoa
import UniformTypeIdentifiers

/// Asks where to save, then renders a recording to MP4 with a progress panel
/// and Cancel. The panel floats over the window instead of a sheet, so tabs
/// and workspaces stay usable during a long export. Reveals the video when done.
@MainActor
final class CastVideoExportController {
    private static var active: [CastVideoExportController] = []

    private let cast: URL
    private let output: URL
    private let panel: NSPanel
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "Preparing…")
    private weak var parent: NSWindow?
    private var task: Task<Void, Never>?

    /// Starts an export of `cast`, attaching its sheets to `window` (or the key window).
    static func run(cast: URL, from window: NSWindow? = nil) {
        let parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let save = NSSavePanel()
        save.title = "Export Video"
        save.prompt = "Export"
        save.allowedContentTypes = [.mpeg4Movie]
        save.canCreateDirectories = true
        save.nameFieldStringValue = CastVideoExporter.defaultFileName(for: cast.path)
        save.directoryURL = cast.deletingLastPathComponent()
        let start: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = save.url else { return }
            let controller = CastVideoExportController(cast: cast, output: url, parent: parent)
            active.append(controller)
            controller.start()
        }
        if let parent {
            save.beginSheetModal(for: parent, completionHandler: start)
        } else {
            start(save.runModal())
        }
    }

    private init(cast: URL, output: URL, parent: NSWindow?) {
        self.cast = cast
        self.output = output
        self.parent = parent
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 118), styleMask: [.titled, .utilityWindow],
            backing: .buffered, defer: true)
        panel.title = "Export Video"
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        buildPanel()
    }

    private func buildPanel() {
        let title = NSTextField(labelWithString: "Exporting “\(output.lastPathComponent)”")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.style = .bar
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView()
        for v in [title, progressBar, detailLabel, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            progressBar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 10),
            cancel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            detailLabel.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8)
        ])
        panel.contentView = content
    }

    private func start() {
        if let parent {
            // Near the top of the window, stepped down per concurrent export.
            let step = CGFloat(Self.active.count - 1) * 24
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.maxY - size.height - 72 - step))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panel.orderFront(nil)
        let cast = cast
        let output = output
        let style = CastVideoExporter.Style.current
        let idle = AppSettings.shared.recordingIdleTimeLimit
        let began = Date()
        // Progress comes back through a stream so the detached render never
        // captures self (older compilers reject that as a data race).
        let (updates, sink) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                defer { sink.finish() }
                try await CastVideoExporter.export(cast: cast, to: output, style: style, idleLimit: idle) {
                    sink.yield($0)
                }
            }
            for await p in updates { self?.update(progress: p, since: began) }
            let result: Error?
            do {
                try await work.valueForwardingCancellation()
                result = nil
            } catch {
                result = error
            }
            self?.finish(error: result)
        }
    }

    private func update(progress: Double, since began: Date) {
        progressBar.doubleValue = progress
        let elapsed = Date().timeIntervalSince(began)
        var text = "\(Int((progress * 100).rounded()))%"
        if progress > 0.05, progress < 1 {
            let remaining = elapsed / progress * (1 - progress)
            text += " · \(CastPlayback.formatTime(remaining)) left"
        }
        detailLabel.stringValue = text
    }

    @objc private func cancel() {
        task?.cancel()
    }

    private func finish(error: Error?) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        Self.active.removeAll { $0 === self }
        switch error {
        case nil:
            NSWorkspace.shared.activateFileViewerSelecting([output])
        case is CancellationError:
            break
        case let error?:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Export Video"
            alert.informativeText = error.localizedDescription
            if let parent {
                alert.beginSheetModal(for: parent)
            } else {
                alert.runModal()
            }
        }
    }
}

extension Task where Failure == Error {
    /// Awaits the value, cancelling this task when the awaiting one is
    /// cancelled (a detached task doesn't inherit cancellation).
    fileprivate func valueForwardingCancellation() async throws -> Success {
        try await withTaskCancellationHandler {
            try await value
        } onCancel: {
            cancel()
        }
    }
}
