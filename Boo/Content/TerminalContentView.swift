import CGhostty
import Cocoa

/// ContentViewProtocol wrapper around GhosttyView.
/// Adapts the terminal-specific GhosttyView to the generic content view interface.
final class TerminalContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .terminal

    /// The underlying Ghostty terminal view.
    private(set) var ghosttyView: GhosttyView

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// Terminal-specific callbacks (forwarded from GhosttyView).
    var onPwdChanged: ((String) -> Void)?
    var onDirectoryListing: ((String, String) -> Void)?
    var onShellPIDDiscovered: ((pid_t) -> Void)?
    var onScrollbarChanged: ((GhosttyView.GhosttyScrollbar) -> Void)?

    // MARK: - State

    private var workingDirectory: String
    private var currentTitle: String = ""

    // MARK: - Init

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        self.ghosttyView = GhosttyView(workingDirectory: workingDirectory)
        super.init(frame: .zero)
        wantsLayer = true
        setupGhosttyView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGhosttyView() {
        addSubview(ghosttyView)
        ghosttyView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ghosttyView.topAnchor.constraint(equalTo: topAnchor),
            ghosttyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            ghosttyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ghosttyView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        wireGhosttyCallbacks()
    }

    private func wireGhosttyCallbacks() {
        ghosttyView.onFocused = { [weak self] in
            self?.onFocused?()
        }

        ghosttyView.onTitleChanged = { [weak self] title in
            self?.currentTitle = title
            self?.onTitleChanged?(title)
        }

        ghosttyView.onPwdChanged = { [weak self] path in
            self?.workingDirectory = path
            self?.onPwdChanged?(path)
        }

        ghosttyView.onDirectoryListing = { [weak self] path, output in
            self?.onDirectoryListing?(path, output)
        }

        ghosttyView.onProcessExited = { [weak self] in
            self?.onCloseRequested?()
        }

        ghosttyView.onShellPIDDiscovered = { [weak self] pid in
            self?.onShellPIDDiscovered?(pid)
        }

        ghosttyView.onScrollbarChanged = { [weak self] scrollbar in
            self?.onScrollbarChanged?(scrollbar)
        }
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(ghosttyView)
    }

    func deactivate() {
        // Terminal stays alive in background, nothing to do
    }

    func cleanup() {
        ghosttyView.destroy()
    }

    func saveState() -> ContentState {
        .terminal(
            TerminalContentState(
                title: currentTitle,
                workingDirectory: workingDirectory,
                shellPID: ghosttyView.shellPID
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .terminal(let terminalState) = state else { return }
        workingDirectory = terminalState.workingDirectory
        currentTitle = terminalState.title
    }

    // MARK: - Terminal-Specific API

    /// The shell PID for this terminal.
    var shellPID: pid_t { ghosttyView.shellPID }

    /// Whether the terminal process has exited.
    var processExited: Bool { ghosttyView.processExited }

    /// Grid size of the terminal.
    var gridSize: ghostty_surface_size_s? { ghosttyView.gridSize }

    /// Send raw text to the terminal.
    func sendRaw(_ text: String) {
        ghosttyView.sendRaw(text)
    }

    /// Send a key press to the terminal.
    func sendKey(keyCode: UInt16, mods: ghostty_input_mods_e, text: String? = nil) {
        ghosttyView.sendKey(keyCode: keyCode, mods: mods, text: text)
    }

    /// Re-walk the process tree to find the current shell PID.
    func refreshShellPIDIfNeeded(currentPID: pid_t) {
        ghosttyView.refreshShellPIDIfNeeded(currentPID: currentPID)
    }

    /// Flash the terminal (visual feedback).
    func flash() {
        ghosttyView.flashTerminal(nil)
    }

    /// Copy the current selection to clipboard.
    func copySelection() {
        ghosttyView.copySelection(nil)
    }

    /// Paste from clipboard.
    func paste() {
        ghosttyView.paste(nil)
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        ghosttyView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        ghosttyView.resignFirstResponder()
    }
}
