import Cocoa

/// One terminal tab that lives outside every window's split tree: the
/// orchestrator drawer and the quick terminal.
///
/// Its `Pane` is a real model (stable pane and tab IDs, so the socket can
/// address it), but no `PaneView` shows it. The terminal moves between
/// containers with `attach(to:)`, which reparents the view without closing the
/// surface, so plugins and process tracking never see a "terminal closed".
/// With no container it is parked in a hidden window so the pty keeps running.
@MainActor
final class DetachedPaneHost {
    let pane: Pane
    var tabID: UUID { pane.tabs[0].id }
    var paneID: UUID { pane.id }

    private(set) var terminal: GhosttyView?
    private var hostView: TerminalScrollView?
    private var holder: NSWindow?
    /// The terminal's last title.
    private(set) var title = ""

    var onTitleChanged: ((String) -> Void)?
    /// The shell (or the command it ran) exited; the terminal is gone.
    var onExited: (() -> Void)?

    init(workingDirectory: String, title: String) {
        pane = Pane()
        pane.addTab(workingDirectory: workingDirectory, title: title)
        self.title = title
    }

    var isRunning: Bool { terminal != nil }

    /// Starts the terminal unless it is running. Parked until attached.
    func start(_ launch: LaunchSpec = LaunchSpec()) {
        guard terminal == nil else { return }
        let tab = pane.tabs[0]
        GhosttyView.pendingLaunch[tab.id] = launch
        let view = GhosttyView(workingDirectory: tab.workingDirectory, paneID: pane.id, tabID: tab.id)
        GhosttyView.pendingLaunch.removeValue(forKey: tab.id)
        view.onTitleChanged = { [weak self] title in
            self?.title = title
            self?.onTitleChanged?(title)
        }
        view.onProcessExited = { [weak self] in self?.stop() }
        terminal = view
        hostView = TerminalScrollView(ghosttyView: view)
        park()
    }

    /// Shows the terminal inside `container`, filling it.
    func attach(to container: NSView) {
        guard let hostView else { return }
        if hostView.superview !== container {
            hostView.removeFromSuperview()
            hostView.frame = container.bounds
            hostView.autoresizingMask = [.width, .height]
            container.addSubview(hostView)
        }
        holder?.orderOut(nil)
        terminal?.refresh()
    }

    /// Moves the terminal to the hidden holder window (drawer closed or its window gone).
    func park() {
        guard let hostView else { return }
        let holder = self.holder ?? Self.makeHolder()
        self.holder = holder
        guard let content = holder.contentView, hostView.superview !== content else { return }
        hostView.removeFromSuperview()
        hostView.frame = content.bounds
        hostView.autoresizingMask = [.width, .height]
        content.addSubview(hostView)
    }

    /// Whether the terminal is shown in `container`.
    func isAttached(to container: NSView) -> Bool {
        hostView?.superview === container
    }

    func focus() {
        guard let terminal, let window = terminal.window, window !== holder else { return }
        window.makeFirstResponder(terminal)
    }

    /// Closes the terminal; `start` opens a fresh one on the same tab.
    func stop() {
        guard let terminal else { return }
        self.terminal = nil
        hostView?.removeFromSuperview()
        hostView = nil
        terminal.destroy()
        onExited?()
    }

    private static func makeHolder() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return window
    }
}
