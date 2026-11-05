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
    let processPID: pid_t?
    let processCategory: String?
    let processMetadata: [String: String]
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
    static let empty = TerminalContext(
        terminalID: UUID(),
        cwd: "",
        remoteSession: nil,
        gitContext: nil,
        processName: "",
        processPID: nil,
        processCategory: nil,
        processMetadata: [:],
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
        processPID: pid_t? = nil,
        processCategory: String? = nil,
        processMetadata: [String: String] = [:],
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
        self.processPID = processPID
        self.processCategory = processCategory
        self.processMetadata = processMetadata
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.enrichedData = enrichedData
    }
}

// MARK: - Builder

extension TerminalContext {
    /// Build a TerminalContext directly from per-tab state (source of truth).
    static func build(
        tabState: TabState,
        terminalID: UUID,
        gitContext: GitContext?,
        processName: String,
        processPID: pid_t? = nil,
        processCategory: String? = nil,
        processMetadata: [String: String] = [:],
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
            processPID: processPID,
            processCategory: processCategory,
            processMetadata: processMetadata,
            paneCount: paneCount,
            tabCount: tabCount
        )
    }
}
