import Foundation

/// Folder navigation shared by the local and remote explorer plugins: open/cd a folder
/// and build the navigation bar's closures. Conformers supply the per-terminal state
/// and how a state change is applied.
@MainActor
protocol FileTreeBrowsing: AnyObject {
    /// Explorer navigation per terminal — lets the tree browse away from the shell's cwd.
    var browseStates: [UUID: FileTreeBrowseState] { get }
    /// Each terminal's cwd as of the last cycle. Navigation closures read it at call time,
    /// so a tree view kept across cycles never acts on a stale cwd.
    var latestCwd: [UUID: String] { get }
    var actions: PluginActions? { get }

    func updateBrowseState(
        _ terminalID: UUID, terminalCwd: String, _ change: (inout FileTreeBrowseState, String) -> Void)
    static func cdCommand(_ path: String) -> String
}

extension FileTreeBrowsing {
    /// Make `path` the root for a terminal, per the navigation-mode setting. `cd` mode falls
    /// back to browsing while an AI agent owns the terminal (the text would hit its prompt).
    func open(_ path: String, terminalID: UUID, terminalCwd: String, canSendToTerminal: Bool) {
        if AppSettings.shared.explorerNavigationMode == .terminal && canSendToTerminal {
            cdTerminal(to: path, terminalID: terminalID, terminalCwd: terminalCwd)
        } else {
            updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.browse(to: path, terminalCwd: $1) }
        }
    }

    /// Type `cd` into the terminal and re-link the explorer, which then follows the shell there.
    func cdTerminal(to path: String, terminalID: UUID, terminalCwd: String) {
        actions?.sendToTerminal?(Self.cdCommand(path))
        updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.attach(terminalCwd: $1) }
    }

    func withLiveCwd(_ tid: UUID, _ body: (Self, String) -> Void) {
        guard let cwd = latestCwd[tid] else { return }
        body(self, cwd)
    }

    /// Generation key for what the navigation bar draws.
    func navigationKey(terminalID: UUID, displayPath: String) -> String {
        let state = browseStates[terminalID] ?? FileTreeBrowseState()
        let mode = AppSettings.shared.explorerNavigationMode.rawValue
        return "\(state.isDetached)|\(state.canGoBack)|\(state.canGoForward)|\(displayPath)|\(mode)"
    }

    /// Closures capture only the terminal's ID and read its cwd/root at call time, so a view
    /// kept across cycles never acts on stale values.
    func makeNavigation(
        terminalID tid: UUID, displayPath: String, canSendToTerminal canSend: Bool
    ) -> FileTreeNavigation {
        let state = browseStates[tid] ?? FileTreeBrowseState()
        let step: (@escaping (inout FileTreeBrowseState, String) -> Void) -> @MainActor () -> Void = { change in
            { [weak self] in self?.withLiveCwd(tid) { $0.updateBrowseState(tid, terminalCwd: $1, change) } }
        }
        return FileTreeNavigation(
            mode: AppSettings.shared.explorerNavigationMode,
            displayPath: displayPath,
            isDetached: state.isDetached,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward,
            canSendToTerminal: canSend,
            open: { [weak self] path in
                self?.withLiveCwd(tid) { $0.open(path, terminalID: tid, terminalCwd: $1, canSendToTerminal: canSend) }
            },
            browse: { path in step { $0.browse(to: path, terminalCwd: $1) }() },
            goBack: step { $0.goBack(terminalCwd: $1) },
            goForward: step { $0.goForward(terminalCwd: $1) },
            attach: step { $0.attach(terminalCwd: $1) },
            cdTerminalHere: { [weak self] in
                self?.withLiveCwd(tid) { plugin, cwd in
                    let root = plugin.browseStates[tid]?.root(terminalCwd: cwd) ?? cwd
                    plugin.cdTerminal(to: root, terminalID: tid, terminalCwd: cwd)
                }
            }
        )
    }
}
