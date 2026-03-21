import Combine
import Foundation

/// Snapshot of the active terminal's state — single source of truth for the focused tab.
/// TabState in Pane.Tab is the persistence copy, synced from bridge on every state change.
struct BridgeState: Equatable {
    var paneID: UUID
    var tabID: UUID = UUID()
    var workspaceID: UUID
    var workingDirectory: String
    var terminalTitle: String
    var foregroundProcess: String
    var remoteSession: RemoteSessionType?
    var remoteCwd: String?
    var isDockerAvailable: Bool

    static let empty = BridgeState(
        paneID: UUID(),
        workspaceID: UUID(),
        workingDirectory: "",
        terminalTitle: "",
        foregroundProcess: "",
        remoteSession: nil,
        remoteCwd: nil,
        isDockerAvailable: false
    )
}

/// Discrete terminal events for subscribers that care about transitions, not snapshots.
enum TerminalEvent: Equatable {
    case directoryChanged(path: String)
    case titleChanged(title: String)
    case processChanged(name: String)
    case remoteSessionChanged(session: RemoteSessionType?)
    case focusChanged(paneID: UUID)
    case workspaceSwitched(workspaceID: UUID)
    case remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry])
}

extension RemoteExplorer.RemoteEntry: Equatable {
    static func == (lhs: RemoteExplorer.RemoteEntry, rhs: RemoteExplorer.RemoteEntry) -> Bool {
        lhs.name == rhs.name && lhs.isDirectory == rhs.isDirectory
    }
}

/// Centralized event bus and state holder for terminal events.
/// One instance per MainWindowController.
final class TerminalBridge {
    @Published private(set) var state: BridgeState
    let events = PassthroughSubject<TerminalEvent, Never>()
    let injector = RemoteShellInjector()
    let monitor = RemoteSessionMonitor()

    /// Most recent in-session directory listing from OSC 2 EXTERM_LS protocol.
    private(set) var cachedRemoteListing: (path: String, entries: [RemoteExplorer.RemoteEntry])?

    /// Process-tree hint per pane, updated by the monitor. Used for reconciliation.
    private var processTreeHint: [UUID: RemoteSessionType?] = [:]

    /// Grace period: when a session is first detected via title, protect it from stale
    /// title events for a short window (until the process tree can confirm/deny).
    private var sessionGraceUntil: [UUID: Date] = [:]

    init(paneID: UUID, workspaceID: UUID, workingDirectory: String) {
        self.state = BridgeState(
            paneID: paneID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            remoteCwd: nil,
            isDockerAvailable: false
        )
        monitor.onSessionChanged = { [weak self] paneID, session in
            self?.handleProcessTreeDetection(session: session, paneID: paneID)
        }
        monitor.onContainerCwdChanged = { [weak self] tabID, cwd in
            self?.handleContainerCwdChange(cwd: cwd, tabID: tabID)
        }
    }

    /// Called by the monitor when a container session's CWD changes (polled from /proc).
    func handleContainerCwdChange(cwd: String, tabID: UUID) {
        guard tabID == state.tabID else { return }
        guard state.remoteSession?.isContainer == true else { return }
        guard cwd != state.remoteCwd else { return }

        remoteLog("[Bridge] container CWD update: \(state.remoteCwd ?? "nil") → \(cwd)")
        state.remoteCwd = cwd
        events.send(.directoryChanged(path: cwd))
    }

    /// Start container CWD polling for the active pane when a container session is
    /// detected by title heuristics. The monitor may not detect the container via
    /// process tree (docker CLI reparenting), so this ensures CWD tracking works.
    func ensureContainerCwdPolling() {
        guard let session = state.remoteSession, session.isContainer else { return }
        monitor.startContainerCwdPolling(paneID: state.paneID, tabID: state.tabID, session: session)
    }

    // MARK: - Input Methods

    /// Restore the full bridge state from the tab model when switching tabs/panes.
    /// Each tab owns its own title, remote session, and CWD. The bridge is just a
    /// window into the currently active tab. This avoids heuristic re-evaluation
    /// which would misinterpret stale local CWDs as "remote session ended".
    func restoreTabState(
        paneID: UUID,
        tabID: UUID,
        workingDirectory: String,
        terminalTitle: String,
        remoteSession: RemoteSessionType?,
        remoteCwd: String?,
        shellPID: pid_t = 0
    ) {
        NSLog(
            "[Bridge] restoreTabState: paneID=\(paneID), cwd=\(workingDirectory), title=\(terminalTitle), remote=\(String(describing: remoteSession)), remoteCwd=\(String(describing: remoteCwd))"
        )
        let previousRemote = state.remoteSession
        state.paneID = paneID
        state.tabID = tabID
        if !workingDirectory.isEmpty {
            state.workingDirectory = workingDirectory
        }
        state.terminalTitle = terminalTitle
        state.remoteSession = remoteSession
        state.remoteCwd = remoteCwd

        // Update the monitor with the active tab's shell PID
        if shellPID > 0 {
            monitor.updateShellPID(paneID: paneID, shellPID: shellPID)
        }

        // Start container CWD polling for the restored tab
        ensureContainerCwdPolling()

        events.send(.focusChanged(paneID: paneID))
        if state.remoteSession != previousRemote {
            events.send(.remoteSessionChanged(session: state.remoteSession))
        }
    }

    func handleFocus(paneID: UUID, workingDirectory: String) {
        state.paneID = paneID
        if !workingDirectory.isEmpty {
            state.workingDirectory = workingDirectory
        }
        events.send(.focusChanged(paneID: paneID))
    }

    func handleDirectoryChange(path: String, paneID: UUID) {
        guard paneID == state.paneID else {
            return
        }

        let previousRemote = state.remoteSession
        NSLog(
            "[Bridge] handleDirectoryChange: path=\(path), title=\(state.terminalTitle), previousRemote=\(String(describing: previousRemote)), currentCwd=\(state.workingDirectory)"
        )

        // If we were remote and the CWD is under the local user's home directory,
        // the SSH/Docker session has ended and the local shell took over.
        // OSC 7 (CWD reporting) only fires from the local shell, so a home-directory
        // path proves the remote session is gone — clear it immediately rather
        // than waiting for the title to update (which may lag).
        // We only check home-directory paths (not /tmp etc.) because common system
        // paths exist on both local and remote hosts.
        // This must happen even when the path hasn't changed (e.g. user was in
        // /Users/phlp, SSH'd somewhere, and returned to /Users/phlp).
        let localHome = FileManager.default.homeDirectoryForCurrentUser.path
        if previousRemote != nil && path.hasPrefix(localHome) {
            NSLog("[Bridge] handleDirectoryChange: local home prefix detected, clearing remote session")
            state.remoteSession = nil
            state.remoteCwd = nil
            state.workingDirectory = path
            if previousRemote != nil { injector.sessionEnded(paneID: paneID) }
            events.send(.remoteSessionChanged(session: nil))
            events.send(.directoryChanged(path: path))
            return
        }

        // If the process-tree monitor confirms no remote child, any CWD change
        // proves the local shell is active (OSC 7 only fires from local shell).
        if previousRemote != nil, let hint = processTreeHint[paneID], hint == nil {
            NSLog("[Bridge] handleDirectoryChange: process tree confirms no remote child, clearing")
            state.remoteSession = nil
            state.remoteCwd = nil
            state.workingDirectory = path
            injector.sessionEnded(paneID: paneID)
            events.send(.remoteSessionChanged(session: nil))
            events.send(.directoryChanged(path: path))
            return
        }

        guard path != state.workingDirectory else {
            NSLog("[Bridge] handleDirectoryChange: path unchanged, skipping")
            return
        }
        state.workingDirectory = path

        state.remoteSession = TerminalBridge.resolveRemoteSession(
            title: state.terminalTitle,
            cwd: path,
            previous: previousRemote,
            preferPreviousForCwdEvent: true
        )
        NSLog("[Bridge] handleDirectoryChange: resolved remote=\(String(describing: state.remoteSession))")

        // When remote, extract remoteCwd from title (OSC-7 path is local-relative)
        if state.remoteSession != nil {
            if let remotePath = TerminalBridge.extractRemoteCwd(from: state.terminalTitle, session: state.remoteSession) {
                state.remoteCwd = remotePath
            }
            // Keep existing remoteCwd if title doesn't have one
        } else {
            state.remoteCwd = nil
        }

        if state.remoteSession != previousRemote {
            events.send(.remoteSessionChanged(session: state.remoteSession))
        }

        events.send(.directoryChanged(path: path))
    }

    func handleTitleChange(title: String, paneID: UUID) {
        guard paneID == state.paneID else { return }
        NSLog("[Bridge] handleTitleChange: title=\(title), paneID=\(paneID)")
        remoteLog("[Bridge] handleTitleChange: title=\(title) remote=\(String(describing: state.remoteSession))")
        state.terminalTitle = title

        let process = TerminalBridge.extractProcessName(from: title)
        let processChanged = process != state.foregroundProcess
        state.foregroundProcess = process

        let previousRemote = state.remoteSession
        var resolved = TerminalBridge.resolveRemoteSession(
            title: title,
            cwd: state.workingDirectory,
            previous: previousRemote
        )

        // Guard against stale title events clearing an active session.
        // On macOS, proc_name/sysctl fail for PTY child processes, so the process
        // tree monitor cannot reliably confirm sessions. Instead we use:
        // 1. processTreeHint (when available from monitor)
        // 2. Grace period — protects new sessions for a few seconds
        // 3. The CWD-based check in handleDirectoryChange (OSC 7 from local shell
        //    is the strongest signal that a remote session ended)
        if resolved == nil, let previousRemote {
            if let hint = processTreeHint[paneID], hint != nil {
                resolved = previousRemote
            } else if let grace = sessionGraceUntil[paneID], Date() < grace {
                // Within grace window after session detection — keep session.
                // Stale local prompt titles often arrive right after docker exec/ssh
                // starts because the shell's precmd fires before the child takes over.
                // Exception: definitive local signals should not be suppressed:
                // - bare shell name ("zsh", "bash") = user exited remote session
                // - local user@host prompt = local shell is active
                let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
                let firstWord = trimmedTitle.split(separator: " ").first.map(String.init) ?? ""
                let isDefinitelyLocal =
                    Self.shellNames.contains(firstWord.lowercased())
                    || Self.titleIsLocalUserAtHost(trimmedTitle)
                if !isDefinitelyLocal {
                    resolved = previousRemote
                }
            }
        }

        state.remoteSession = resolved

        // Extract remoteCwd from title and handle session switches
        if state.remoteSession != nil {
            // Session host changed → reset remoteCwd before re-extracting
            if state.remoteSession != previousRemote {
                state.remoteCwd = nil
            }
            if let remotePath = TerminalBridge.extractRemoteCwd(from: title, session: state.remoteSession) {
                remoteLog("[Bridge] extractRemoteCwd: title=\(title) → remoteCwd=\(remotePath)")
                state.remoteCwd = remotePath
            }
        } else {
            state.remoteCwd = nil
        }

        events.send(.titleChanged(title: title))
        if processChanged {
            events.send(.processChanged(name: process))
        }
        if state.remoteSession != previousRemote {
            events.send(.remoteSessionChanged(session: state.remoteSession))

            // When a new session is detected via title, set a grace period to protect
            // it from stale title events (e.g., local prompt title arriving after
            // docker exec starts). The grace window is 3s — enough for the process
            // tree monitor to poll and confirm/deny the session.
            if state.remoteSession != nil && previousRemote == nil {
                sessionGraceUntil[paneID] = Date().addingTimeInterval(3.0)
                // Start container CWD polling (process tree may not detect docker)
                ensureContainerCwdPolling()
            }
            // Clean up injection state when remote session ends
            if previousRemote != nil && state.remoteSession == nil {
                injector.sessionEnded(paneID: state.paneID)
            }
        }
    }

    func handleDirectoryListing(path: String, output: String, paneID: UUID) {
        guard paneID == state.paneID else { return }
        let entries = TerminalBridge.parseLsOutput(output)
        cachedRemoteListing = (path: path, entries: entries)
        events.send(.remoteDirectoryListed(path: path, entries: entries))
    }

    /// Parse `ls -1AF` output into RemoteEntry array.
    static func parseLsOutput(_ output: String) -> [RemoteExplorer.RemoteEntry] {
        var entries: [RemoteExplorer.RemoteEntry] = []
        for line in output.split(separator: "\n") {
            var name = String(line)
            let isDir = name.hasSuffix("/")
            if isDir { name = String(name.dropLast()) }
            if let last = name.last, "@*|=".contains(last) { name = String(name.dropLast()) }
            guard !name.isEmpty else { continue }
            entries.append(RemoteExplorer.RemoteEntry(name: name, isDirectory: isDir))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    func handleProcessExit(paneID: UUID) {
        guard paneID == state.paneID else { return }
        let hadRemote = state.remoteSession != nil
        if state.remoteSession != nil {
            injector.sessionEnded(paneID: state.paneID)
        }
        state.remoteSession = nil
        state.remoteCwd = nil
        state.foregroundProcess = ""
        state.terminalTitle = ""
        if hadRemote {
            events.send(.remoteSessionChanged(session: nil))
        }
    }

    // MARK: - Process Tree Detection

    /// Called by the monitor when process-tree inspection detects a state change.
    /// Process tree is authoritative: it overrides title heuristics.
    func handleProcessTreeDetection(session: RemoteSessionType?, paneID: UUID) {
        processTreeHint[paneID] = session
        sessionGraceUntil.removeValue(forKey: paneID)  // Process tree is authoritative now
        guard paneID == state.paneID else { return }

        let previous = state.remoteSession
        let resolved = reconcileWithProcessTree(titleSession: previous, processSession: session)

        guard resolved != previous else { return }

        NSLog(
            "[Bridge] processTree: \(String(describing: session)) → resolved=\(String(describing: resolved)) (was \(String(describing: previous)))"
        )

        state.remoteSession = resolved
        if resolved == nil {
            state.remoteCwd = nil
            if previous != nil {
                injector.sessionEnded(paneID: paneID)
            }
        } else if previous == nil {
            // New session detected — inject CWD reporter
            injector.injectIfNeeded(paneID: paneID)
        }
        events.send(.remoteSessionChanged(session: resolved))
    }

    /// Reconcile title-based heuristic with process-tree detection.
    /// Process tree is authoritative for END (no child = no remote).
    /// Process tree is strong for START (child found = adopt it).
    /// When process tree says Docker but title says SSH, prefer process tree.
    private func reconcileWithProcessTree(
        titleSession: RemoteSessionType?, processSession: RemoteSessionType?
    ) -> RemoteSessionType? {
        // Process tree says no remote child — authoritative END
        guard let process = processSession else { return nil }

        // Process tree detected something
        if let title = titleSession {
            // Both agree on SSH — merge: title has better host info, process has alias
            if case .ssh(let titleHost, let titleAlias) = title,
                case .ssh(let processHost, _) = process
            {
                let alias = titleAlias ?? processHost
                return .ssh(host: titleHost, alias: alias)
            }
            // Both agree on mosh — title has better info
            if case .mosh = title, case .mosh = process { return title }
            // Both agree on container type — prefer title (may have better name)
            if case .container = title, case .container = process { return title }
            // Process says container, title says SSH (container hostname looks like user@host)
            // — prefer process tree
            if case .ssh = title, case .container = process { return process }
        }

        return process
    }

    func switchContext(paneID: UUID, workspaceID: UUID, workingDirectory: String) {
        state = BridgeState(
            paneID: paneID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            remoteCwd: nil,
            isDockerAvailable: state.isDockerAvailable
        )
        events.send(.workspaceSwitched(workspaceID: workspaceID))
    }

}
