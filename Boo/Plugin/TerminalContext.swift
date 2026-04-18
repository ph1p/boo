import Foundation

/// Immutable snapshot of a terminal's context at a point in time.
/// Value type — plugins in the react phase receive a frozen copy.
/// ADR-1: TerminalContext as Value Type.
struct TerminalContext: Equatable, @unchecked Sendable {
    let terminalID: UUID
    let cwd: String
    let remoteSession: RemoteSessionType?
    let remoteCwd: String?
    let gitContext: GitContext?
    let processName: String
    let paneCount: Int
    let tabCount: Int

    /// Plugin-contributed data from the enrich phase, keyed by plugin-namespaced keys.
    /// Plugins write via EnrichmentContext.setData() in Phase 1; all plugins read in Phase 2.
    let enrichedData: [String: AnyHashable]

    /// Git repository context, if the terminal is in a git repo.
    struct GitContext: Equatable {
        let branch: String
        let repoRoot: String
        let isDirty: Bool
        let changedFileCount: Int
        let stagedCount: Int
        let aheadCount: Int
        let behindCount: Int
        let lastCommitShort: String?
    }

    /// Empty context used as a default before any terminal state is available.
    nonisolated(unsafe) static let empty = TerminalContext(
        terminalID: UUID(),
        cwd: "",
        remoteSession: nil,
        gitContext: nil,
        processName: "",
        paneCount: 0,
        tabCount: 0
    )

    /// Whether this terminal is in a remote session.
    var isRemote: Bool { remoteSession != nil }

    /// Environment description for display and VoiceOver.
    var environmentLabel: String {
        guard let session = remoteSession else { return "local" }
        return "\(session.envType): \(session.displayName)"
    }

    init(
        terminalID: UUID,
        cwd: String,
        remoteSession: RemoteSessionType?,
        remoteCwd: String? = nil,
        gitContext: GitContext?,
        processName: String,
        paneCount: Int,
        tabCount: Int,
        enrichedData: [String: AnyHashable] = [:]
    ) {
        self.terminalID = terminalID
        self.cwd = cwd
        self.remoteSession = remoteSession
        self.remoteCwd = remoteCwd
        self.gitContext = gitContext
        self.processName = processName
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.enrichedData = enrichedData
    }
}

// MARK: - Builder

extension TerminalContext {
    /// Build a TerminalContext from existing BridgeState and StatusBarState.
    /// Bridges the current state system into the new structured format.
    static func build(
        from terminalState: BridgeState,
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
                changedFileCount: 0,
                stagedCount: 0,

                aheadCount: 0,
                behindCount: 0,
                lastCommitShort: nil
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

    /// Build a TerminalContext directly from per-tab state (source of truth).
    static func build(
        tabState: TabState,
        terminalID: UUID,
        gitContext: GitContext?,
        processName: String,
        paneCount: Int,
        tabCount: Int
    ) -> TerminalContext {
        TerminalContext(
            terminalID: terminalID,
            cwd: tabState.workingDirectory,
            remoteSession: tabState.remoteSession,
            remoteCwd: tabState.remoteWorkingDirectory,
            gitContext: gitContext,
            processName: processName,
            paneCount: paneCount,
            tabCount: tabCount
        )
    }
}
