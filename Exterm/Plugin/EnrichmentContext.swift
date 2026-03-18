import Foundation

/// Mutable wrapper for the enrich phase.
/// Plugins write to this during Phase 1, then it freezes into an immutable TerminalContext.
/// ADR-1: Enrichment wrapper constrains mutation to a single, supervised phase.
@MainActor
final class EnrichmentContext {
    private(set) var terminalID: UUID
    private(set) var cwd: String
    private(set) var remoteSession: RemoteSessionType?
    private(set) var remoteCwd: String?
    private(set) var processName: String
    private(set) var paneCount: Int
    private(set) var tabCount: Int

    /// Git context — enriched by the git plugin during Phase 1.
    var gitBranch: String?
    var gitRepoRoot: String?
    var gitIsDirty: Bool = false
    var gitChangedFileCount: Int = 0

    /// Additional key-value data plugins can contribute.
    private var enrichedData: [String: Any] = [:]

    private var isFrozen = false

    init(base: TerminalContext) {
        self.terminalID = base.terminalID
        self.cwd = base.cwd
        self.remoteSession = base.remoteSession
        self.remoteCwd = base.remoteCwd
        self.processName = base.processName
        self.paneCount = base.paneCount
        self.tabCount = base.tabCount
        self.gitBranch = base.gitContext?.branch
        self.gitRepoRoot = base.gitContext?.repoRoot
        self.gitIsDirty = base.gitContext?.isDirty ?? false
        self.gitChangedFileCount = base.gitContext?.changedFileCount ?? 0
    }

    /// Set enriched data by key. Only allowed during enrich phase.
    func setData(_ value: Any, forKey key: String) {
        guard !isFrozen else { return }
        enrichedData[key] = value
    }

    /// Get enriched data by key.
    func getData(forKey key: String) -> Any? {
        enrichedData[key]
    }

    /// Freeze into an immutable TerminalContext. Called at the phase boundary.
    func freeze() -> TerminalContext {
        isFrozen = true

        let gitContext: TerminalContext.GitContext?
        if let branch = gitBranch, let repoRoot = gitRepoRoot {
            gitContext = TerminalContext.GitContext(
                branch: branch,
                repoRoot: repoRoot,
                isDirty: gitIsDirty,
                changedFileCount: gitChangedFileCount
            )
        } else {
            gitContext = nil
        }

        return TerminalContext(
            terminalID: terminalID,
            cwd: cwd,
            remoteSession: remoteSession,
            remoteCwd: remoteCwd,
            gitContext: gitContext,
            processName: processName,
            paneCount: paneCount,
            tabCount: tabCount
        )
    }
}
