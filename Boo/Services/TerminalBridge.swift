import Combine
import Foundation

/// Snapshot of the active terminal's state — single source of truth for the focused tab.
/// TabState in Pane.Tab is the persistence copy, synced from bridge on every state change.
/// A command currently executing in the shell (detected via OSC 9999 shell integration).
struct RunningCommand: Equatable {
    let command: String
    let startTime: Date
}

/// Result of a completed command (exit code + duration).
struct CommandResult: Equatable {
    let command: String
    let exitCode: Int32
    let duration: TimeInterval
}

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
    /// Currently executing command (nil when shell prompt is shown).
    var currentCommand: RunningCommand?
    /// Most recent completed command result.
    var lastCommandResult: CommandResult?

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
    case commandStarted(command: String)
    case commandEnded(result: CommandResult)
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

    /// Resolve the foreground process name from title + socket registration.
    private func resolveProcess(paneID: UUID, title: String) -> String {
        if BooSocketServer.shared.hasActiveProcesses,
            let shellPID = monitor.shellPID(for: paneID),
            let status = BooSocketServer.shared.activeProcess(shellPID: shellPID)
        {
            return status.name
        }
        return TerminalBridge.extractProcessName(from: title)
    }

    /// Re-evaluate the foreground process based on socket-registered processes.
    /// Called when the BooSocketServer's status set changes.
    func reevaluateSocketProcess() {
        let process = resolveProcess(paneID: state.paneID, title: state.terminalTitle)
        if state.foregroundProcess != process {
            state.foregroundProcess = process
            events.send(.processChanged(name: process))
        }
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
        booLog(
            .debug, .terminal,
            "restoreTabState: paneID=\(paneID), cwd=\(workingDirectory), title=\(terminalTitle), remote=\(String(describing: remoteSession)), remoteCwd=\(String(describing: remoteCwd))"
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

        booLog(
            .debug, .terminal,
            "restoreTabState: pane=\(paneID.uuidString.prefix(8)) title=\(terminalTitle) prevProcess=\(state.foregroundProcess)"
        )

        let previousProcess = state.foregroundProcess
        // When restoring a tab with no known shell PID (e.g. a brand-new tab), skip the
        // socket-server lookup — the previous pane's shell PID is still registered and would
        // incorrectly return the old foreground process (e.g. "claude") for the new tab.
        if shellPID > 0 {
            state.foregroundProcess = resolveProcess(paneID: paneID, title: terminalTitle)
            monitor.updateShellPID(paneID: paneID, shellPID: shellPID)
        } else {
            state.foregroundProcess = TerminalBridge.extractProcessName(from: terminalTitle)
        }

        // Start container CWD polling for the restored tab
        ensureContainerCwdPolling()

        events.send(.focusChanged(paneID: paneID))
        if state.foregroundProcess != previousProcess {
            events.send(.processChanged(name: state.foregroundProcess))
        }
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
        booLog(
            .debug, .terminal,
            "handleDirectoryChange: path=\(path), title=\(state.terminalTitle), previousRemote=\(String(describing: previousRemote)), currentCwd=\(state.workingDirectory)"
        )

        // If we were remote and the CWD is under the local user's home directory,
        // the SSH/Docker session has ended and the local shell took over.
        // OSC 7 (CWD reporting) only fires from the local shell, so a home-directory
        // path proves the remote session is gone — clear it immediately rather
        // than waiting for the title to update (which may lag).
        // We only check home-directory paths (not /tmp etc.) because common system
        // paths exist on both local and remote hosts.
        // This must happen even when the path hasn't changed (e.g. user was in
        // /Users/jane, SSH'd somewhere, and returned to /Users/jane).
        let localHome = FileManager.default.homeDirectoryForCurrentUser.path
        if previousRemote != nil && path.hasPrefix(localHome) {
            booLog(.debug, .terminal, "handleDirectoryChange: local home prefix detected, clearing remote session")
            state.remoteSession = nil
            state.remoteCwd = nil
            state.workingDirectory = path
            events.send(.remoteSessionChanged(session: nil))
            events.send(.directoryChanged(path: path))
            return
        }

        // If the process-tree monitor confirms no remote child, any CWD change
        // proves the local shell is active (OSC 7 only fires from local shell).
        if previousRemote != nil, let hint = processTreeHint[paneID], hint == nil {
            booLog(.debug, .terminal, "handleDirectoryChange: process tree confirms no remote child, clearing")
            state.remoteSession = nil
            state.remoteCwd = nil
            state.workingDirectory = path
            events.send(.remoteSessionChanged(session: nil))
            events.send(.directoryChanged(path: path))
            return
        }

        guard path != state.workingDirectory else {
            booLog(.debug, .terminal, "handleDirectoryChange: path unchanged, skipping")
            return
        }
        state.workingDirectory = path

        state.remoteSession = TerminalBridge.resolveRemoteSession(
            title: state.terminalTitle,
            cwd: path,
            previous: previousRemote,
            preferPreviousForCwdEvent: true
        )
        booLog(.debug, .terminal, "handleDirectoryChange: resolved remote=\(String(describing: state.remoteSession))")

        // When remote, extract remoteCwd from title (OSC-7 path is local-relative)
        if state.remoteSession != nil {
            if let remotePath = TerminalBridge.extractRemoteCwd(from: state.terminalTitle, session: state.remoteSession)
            {
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
        guard title != state.terminalTitle else { return }
        booLog(.debug, .terminal, "titleChanged: \(title) pane=\(paneID.uuidString.prefix(8))")
        state.terminalTitle = title

        let process = resolveProcess(paneID: paneID, title: title)
        let processChanged = process != state.foregroundProcess
        state.foregroundProcess = process
        if processChanged {
            booLog(
                .debug, .terminal,
                "processChanged: \(state.foregroundProcess.isEmpty ? "(empty)" : state.foregroundProcess) pane=\(paneID.uuidString.prefix(8))"
            )
        }

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
        state.remoteSession = nil
        state.remoteCwd = nil
        state.foregroundProcess = ""
        state.terminalTitle = ""
        if hadRemote {
            events.send(.remoteSessionChanged(session: nil))
        }
    }

    // MARK: - Command Tracking (OSC 9999 Shell Integration)

    /// Called by GhosttyRuntime when OSC 9999 `cmd_start` fires.
    func handleCommandStart(command: String, paneID: UUID) {
        guard paneID == state.paneID else { return }
        state.currentCommand = RunningCommand(command: command, startTime: Date())
        booLog(.debug, .terminal, "cmd_start: \(command.prefix(80))")
        events.send(.commandStarted(command: command))
    }

    /// Called by GhosttyRuntime when OSC 9999 `cmd_end` fires.
    func handleCommandEnd(exitCode: Int32, paneID: UUID) {
        guard paneID == state.paneID, let running = state.currentCommand else { return }
        let duration = Date().timeIntervalSince(running.startTime)
        let result = CommandResult(command: running.command, exitCode: exitCode, duration: duration)
        state.lastCommandResult = result
        state.currentCommand = nil
        booLog(.debug, .terminal, "cmd_end: exit=\(exitCode) duration=\(String(format: "%.2f", duration))s")
        events.send(.commandEnded(result: result))
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

        booLog(
            .debug, .terminal,
            "processTree: \(String(describing: session)) → resolved=\(String(describing: resolved)) (was \(String(describing: previous)))"
        )

        state.remoteSession = resolved
        if resolved == nil {
            state.remoteCwd = nil
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
        debugLog(
            "[WorkspaceSwitch] bridgeSwitch workspace=\(workspaceID.uuidString) pane=\(paneID.uuidString) cwd=\(workingDirectory)"
        )
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
