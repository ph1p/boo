import Foundation

/// Immutable snapshot of a terminal's context at a point in time.
/// Value type — plugins in the react phase receive a frozen copy.
/// ADR-1: TerminalContext as Value Type.
struct TerminalContext: Equatable {
    let terminalID: UUID
    let cwd: String
    let remoteSession: RemoteSessionType?
    let remoteCwd: String?
    let gitContext: GitContext?
    let processName: String
    let paneCount: Int
    let tabCount: Int

    /// Git repository context, if the terminal is in a git repo.
    struct GitContext: Equatable {
        let branch: String
        let repoRoot: String
        let isDirty: Bool
        let changedFileCount: Int
    }

    /// Whether this terminal is in a remote session.
    var isRemote: Bool { remoteSession != nil }

    /// Environment description for display and VoiceOver.
    var environmentLabel: String {
        guard let session = remoteSession else { return "local" }
        switch session {
        case .ssh(let host): return "ssh: \(host)"
        case .docker(let container): return "docker: \(container)"
        }
    }

    init(
        terminalID: UUID,
        cwd: String,
        remoteSession: RemoteSessionType?,
        remoteCwd: String? = nil,
        gitContext: GitContext?,
        processName: String,
        paneCount: Int,
        tabCount: Int
    ) {
        self.terminalID = terminalID
        self.cwd = cwd
        self.remoteSession = remoteSession
        self.remoteCwd = remoteCwd
        self.gitContext = gitContext
        self.processName = processName
        self.paneCount = paneCount
        self.tabCount = tabCount
    }
}

// MARK: - Builder

extension TerminalContext {
    /// Build a TerminalContext from existing TerminalState and StatusBarState.
    /// Bridges the current state system into the new structured format.
    static func build(
        from terminalState: TerminalState,
        gitBranch: String? = nil,
        gitRepoRoot: String? = nil,
        paneCount: Int = 1,
        tabCount: Int = 1
    ) -> TerminalContext {
        let gitContext: GitContext?
        if let branch = gitBranch, let repoRoot = gitRepoRoot {
            gitContext = GitContext(
                branch: branch,
                repoRoot: repoRoot,
                isDirty: false,
                changedFileCount: 0
            )
        } else {
            gitContext = nil
        }

        return TerminalContext(
            terminalID: terminalState.paneID,
            cwd: terminalState.workingDirectory,
            remoteSession: terminalState.remoteSession,
            remoteCwd: terminalState.remoteCwd,
            gitContext: gitContext,
            processName: terminalState.foregroundProcess,
            paneCount: paneCount,
            tabCount: tabCount
        )
    }
}
