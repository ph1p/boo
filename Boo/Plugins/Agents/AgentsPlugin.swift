import AppKit
import SwiftUI

// MARK: - Constants

private enum AgentsConstants {
    /// Maximum directory depth when walking up to find project root
    static let maxProjectRootDepth = 20
    /// Debounce delay for diff detection (seconds)
    static let diffDebounceDelay: TimeInterval = 0.2
    /// Refresh timer interval for diff stats (seconds)
    static let diffRefreshInterval: TimeInterval = 10
}

// MARK: - Cached Formatters

private let relativeDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
}()

/// Built-in Agent Center plugin.
/// Shows active AI agent sessions, setup health, config, skills, MCP servers, and changed files.
/// V1 keeps Claude Code as the richest provider while preparing Codex and OpenCode scanners.
@MainActor
final class AgentsPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "agents",
        name: "Agents",
        version: "1.0.0",
        icon: "sparkles",
        description: "Agent Center for Claude Code, Codex, OpenCode, and AI CLI sessions",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 20, template: nil),
        settings: [
            PluginManifest.SettingManifest(
                key: "settingsPage",
                type: .string,
                label: "Settings Page",
                defaultValue: AnyCodableValue("custom"),
                options: nil,
                group: "Agents")
        ]
    )

    var prefersOuterScrollView: Bool { true }

    func isVisible(for context: TerminalContext) -> Bool {
        AppSettings.shared.isPluginEnabled(pluginID)
    }

    var subscribedEvents: Set<PluginEvent> {
        [.processChanged, .cwdChanged, .focusChanged]
    }

    // MARK: - Cached State

    /// Which agent CLIs are installed on this machine (populated async at startup).
    /// Defaults to all kinds so the UI is not empty during the initial check.
    private(set) var installedAgents: Set<AgentKind> = Set(AgentKind.allCases).subtracting([.custom])

    private(set) var agentStartTime: Date?
    private(set) var activeAgent: AgentSession?
    var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []
    var worktrees: [ClaudeWorktree] = []
    var agentConfig: AgentConfig = AgentConfig()
    /// Session ID currently being written to (detected via file watching)
    private(set) var activeSessionID: String?

    private var lastDiffRepoRoot: String?
    var configScan = ScanStamp()
    var worktreeScan = ScanStamp()
    static let scanTTL: TimeInterval = 15

    /// Memoized `findAgentProjectRoot` result, keyed on the cwd that produced it.
    ///
    /// The config and worktree scans run back-to-back from the same three call sites
    /// and each used to dispatch its own 20-level x 4-marker `fileExists` walk for the
    /// identical cwd. One resolution now feeds both, and a cwd cycling through focus
    /// repeatedly — the common case — pays for none.
    private var projectRootCache: (cwd: String, root: String)?

    /// Resolve the project root for `cwd` and hand it to `body` on the main actor.
    /// The walk runs off the main thread only when the cache misses.
    func withProjectRoot(cwd: String, _ body: @escaping @MainActor (String) -> Void) {
        if let cached = projectRootCache, cached.cwd == cwd {
            body(cached.root)
            return
        }
        let markers = Self.projectMarkers
        DispatchQueue.global(qos: .utility).async {
            let root = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.projectRootCache = (cwd, root)
                body(root)
            }
        }
    }

    /// Root + completion time of the last scan, with the TTL gate both scans share.
    struct ScanStamp {
        private var root: String?
        private var at: TimeInterval = 0

        /// True when a scan should run for `root`, claiming the slot if so.
        /// Root equality alone made the results permanently sticky: a new CLAUDE.md,
        /// skill, or worktree in the *same* root never appeared until the user cd'd
        /// elsewhere and back — hence the TTL.
        mutating func shouldScan(root: String, ttl: TimeInterval) -> Bool {
            let now = booUptime()
            if self.root == root, now - at < ttl { return false }
            self.root = root
            at = now
            return true
        }

        /// Drop the claim so the next request re-scans, keeping the current rows.
        mutating func invalidate() {
            root = nil
            at = 0
        }
    }

    private var refreshTimer: DispatchSourceTimer?
    private let diffDebouncer = Debouncer(delay: AgentsConstants.diffDebounceDelay)
    private var teardownGeneration: UInt64 = 0
    var teardownGracePeriod: TimeInterval = 0.3

    /// Git diff stat entry for changed files.
    struct DiffStatEntry: Identifiable {
        let id = UUID()
        let path: String
        let insertions: Int
        let deletions: Int
        let fullPath: String
    }

    nonisolated static let projectMarkers = [".git", ".claude", "AGENTS.md", "CLAUDE.md"]

    /// A git worktree belonging to the current project (isolated branch for parallel work).
    /// Sourced from `git worktree list`, so it covers worktrees created by any tool,
    /// not just those under `.claude/worktrees`.
    struct ClaudeWorktree: Identifiable {
        let id: String  // Full path — unique, unlike the directory slug
        let path: String  // Full path to worktree directory
        let branch: String  // Branch name, or "detached @ <sha>" when headless
        let headCommit: String?  // Current HEAD SHA (short)
        let created: Date?  // Creation timestamp from directory
    }

    struct AgentConfig {
        var configFiles: [ConfigFile] = []
        var skills: [SkillEntry] = []
        var setupRecommendations: [AgentSetupRecommendation] = []
        var toolSummaries: [AgentToolSummary] = []

        struct ConfigFile: Identifiable {
            let id = UUID()
            let name: String
            let path: String
            let icon: String
            let scope: String
            let provider: AgentKind

            init(name: String, path: String, icon: String, scope: String, provider: AgentKind = .claudeCode) {
                self.name = name
                self.path = path
                self.icon = icon
                self.scope = scope
                self.provider = provider
            }
        }

        struct SkillEntry: Identifiable {
            let id = UUID()
            let name: String
            let description: String
            let path: String
            let provider: AgentKind

            init(name: String, description: String, path: String, provider: AgentKind = .claudeCode) {
                self.name = name
                self.description = description
                self.path = path
                self.provider = provider
            }
        }

    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        guard let start = agentStartTime else { return }
        context.setData(AnyHashable(activeAgent?.kind.rawValue ?? "ai"), forKey: "ai-agent.kind")
        context.setData(AnyHashable(activeAgent?.displayName ?? "Agent"), forKey: "ai-agent.name")
        let runtime = Int(Date().timeIntervalSince(start))
        context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let start = agentStartTime else { return nil }
        var text = activeAgent?.kind.shortName ?? "Agent"
        if !diffStats.isEmpty {
            let count = diffStats.count
            text += " \u{00B7} \(count) file\(count == 1 ? "" : "s")"
        }
        let mins = Int(Date().timeIntervalSince(start) / 60)
        if mins > 0 {
            text += " \u{00B7} \(formatAgentRuntime(Date().timeIntervalSince(start)))"
        }
        return StatusBarContent(
            text: text,
            icon: "sparkles",
            tint: .accent,
            accessibilityLabel: "Agent Center: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard let start = agentStartTime else { return nil }
        let runtime = Date().timeIntervalSince(start)
        return "\(activeAgent?.kind.shortName ?? "Agent") \u{00B7} \(formatAgentRuntime(runtime))"
    }

    // MARK: - Sidebar Tab (multi-section)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }

        // If no agent running, scan config/sessions/worktrees based on current terminal CWD
        let isAgentActive = agentStartTime != nil
        if !isAgentActive && currentCwd != context.terminal.cwd {
            scanAgentConfig(cwd: context.terminal.cwd)
            scanWorktrees(cwd: context.terminal.cwd)
        }

        let act = actions
        let fontScale = context.fontScale
        let textColor = Color(nsColor: context.theme.chromeText)
        let mutedColor = Color(nsColor: context.theme.chromeMuted)
        let accentColor = Color(nsColor: context.theme.accentColor)

        var sections: [SidebarSection] = []

        let openSessions = actions?.workspaceAgentSessions?() ?? []
        if !openSessions.isEmpty {
            let openSessionsSection = SidebarSection(
                id: "agents.open.sessions",
                name: "Open Sessions (\(openSessions.count))",
                icon: "rectangle.3.group",
                content: AnyView(
                    AgentOpenSessionsView(
                        sessions: openSessions,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onSessionClicked: { session in
                            act?.focusAgentSession?(session.id)
                        },
                        onResume: { [weak self] session in
                            self?.startAgent(
                                kind: session.agent.kind,
                                cwd: session.agent.cwd,
                                resumeSessionID: session.agent.sessionID)
                        },
                        onCopySessionID: { session in
                            guard let id = session.agent.sessionID else { return }
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: id))
                        },
                        onOpenTranscript: { session in
                            guard let path = session.agent.transcriptPath else { return }
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(
                    for: openSessions.map {
                        "\($0.id)|\($0.tabTitle)|\($0.isFocused)|\($0.agent.state.rawValue)"
                    }))
            sections.append(openSessionsSection)
        }

        // Changes section — the diff-stat poll already runs while an agent is active
        // and feeds the status bar's file count; surface the per-file rows too.
        if !diffStats.isEmpty {
            let changesSection = SidebarSection(
                id: "agents.changes",
                name: "Changes (\(diffStats.count))",
                icon: "plusminus",
                content: AnyView(
                    ClaudeChangesView(
                        diffStats: diffStats,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onReferenceInAI: { path in
                            act?.sendToTerminal?("@\(path) ")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(
                    for:
                        diffStats.map { "\($0.path)|\($0.insertions)|\($0.deletions)" }))
            sections.append(changesSection)
        }

        // Worktrees section
        if !worktrees.isEmpty {
            let worktreesSection = SidebarSection(
                id: "agents.claude.worktrees",
                name: "Worktrees (\(worktrees.count))",
                icon: "arrow.triangle.branch",
                content: AnyView(
                    ClaudeWorktreesView(
                        worktrees: worktrees,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onWorktreeClicked: { [weak self] worktree in
                            self?.openWorktree(worktree)
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        }
                    )),
                prefersOuterScrollView: true,
                // Count alone is not enough: switching to a project with the same
                // number of worktrees left the previous project's rows on screen.
                generation: SidebarSection.generation(
                    for: worktrees.map { "\($0.path)|\($0.branch)|\($0.headCommit ?? "")" }))
            sections.append(worktreesSection)
        }

        // Config section
        if !agentConfig.configFiles.isEmpty {
            let configSection = SidebarSection(
                id: "agents.config",
                name: "Config (\(agentConfig.configFiles.count))",
                icon: "doc.text",
                content: AnyView(
                    ClaudeConfigView(
                        configFiles: agentConfig.configFiles,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onReferenceInAI: { path in
                            act?.sendToTerminal?("@\(path) ")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(for: agentConfig.configFiles.map { "\($0.path)|\($0.scope)" }))
            sections.append(configSection)
        }

        // Skills section
        if !agentConfig.skills.isEmpty {
            let skillsSection = SidebarSection(
                id: "agents.skills",
                name: "Skills (\(agentConfig.skills.count))",
                icon: "star",
                content: AnyView(
                    ClaudeSkillsView(
                        skills: agentConfig.skills,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onPasteSkill: { name in
                            act?.sendToTerminal?("/\(name)")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(for: agentConfig.skills.map { "\($0.path)|\($0.name)" }))
            sections.append(skillsSection)
        }

        // If no sections (no agent, no sessions, no config), show getting started
        if sections.isEmpty {
            let available = [AgentKind.claudeCode, .codex, .openCode]
                .filter { installedAgents.contains($0) }
            let emptyContent: AnyView
            if available.isEmpty {
                emptyContent = AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No agent CLIs installed")
                            .font(fontScale.font(.base))
                            .foregroundStyle(textColor)
                        Text("Install claude, codex, or opencode to get started.")
                            .font(fontScale.font(.sm))
                            .foregroundStyle(mutedColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                )
            } else {
                emptyContent = AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No active agent in this tab")
                            .font(fontScale.font(.base))
                            .foregroundStyle(textColor)
                        Text("Start an agent here to see workspace sessions.")
                            .font(fontScale.font(.sm))
                            .foregroundStyle(mutedColor)
                        HStack(spacing: 8) {
                            ForEach(available, id: \.self) { kind in
                                Button("Start \(kind.shortName)") { self.startAgent(kind: kind) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                )
            }
            let emptySection = SidebarSection(
                id: "agents.empty",
                name: "Agents",
                icon: "sparkles",
                content: emptyContent,
                prefersOuterScrollView: false,
                generation: SidebarSection.generation(
                    for: installedAgents.map(\.rawValue).sorted()))
            sections.append(emptySection)
        }

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: sections)
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }

    /// Launch an agent CLI in a new tab. When `resumeSessionID` is set, resume that
    /// session instead of starting a fresh one — the "Resume" affordance in Open
    /// Sessions was previously starting a brand-new session and losing the history.
    private func startAgent(kind: AgentKind, cwd: String? = nil, resumeSessionID: String? = nil) {
        let cwd = cwd ?? currentCwd ?? activeAgent?.cwd ?? "~"
        var command: String
        switch kind {
        case .claudeCode:
            command = "claude"
            if let id = resumeSessionID { command += " --resume \(shellEscape(id))" }
        case .codex:
            command = "codex"
            if let id = resumeSessionID { command += " resume \(shellEscape(id))" }
        case .openCode:
            command = "opencode"
            if let id = resumeSessionID { command += " --session \(shellEscape(id))" }
        case .custom:
            return
        }
        actions?.openTab?(.terminalWithCommand(workingDirectory: cwd, command: command))
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        adoptAgent(from: context, trigger: .processChanged)
    }

    /// Shared handling for the process- and focus-change paths, which differ only in
    /// what `trigger` selects and in what they do when no agent is present.
    /// What brought us here. A new process is where a session ID first becomes
    /// visible and where a rerun is needed to surface the agent that just appeared;
    /// a focus change is neither.
    enum AdoptTrigger {
        case processChanged
        case focusChanged
    }

    @discardableResult
    private func adoptAgent(from context: TerminalContext, trigger: AdoptTrigger) -> Bool {
        let active = Self.agentSession(from: context, existingStart: agentStartTime)
        guard let active else {
            if agentStartTime != nil {
                scheduleDeferredTeardown()
            }
            return false
        }

        cancelTeardown()
        if agentStartTime == nil {
            agentStartTime = active.startedAt
            currentCwd = context.cwd
            if trigger == .processChanged { onRequestCycleRerun?() }
            scanAgentConfig(cwd: context.cwd)
            scanWorktrees(cwd: context.cwd)
        }
        activeAgent = active
        if trigger == .processChanged, let sessionID = active.sessionID, activeSessionID != sessionID {
            activeSessionID = sessionID
            actions?.setAgentSessionID?(sessionID)
        }
        refreshDiffStats(repoRoot: context.gitContext?.repoRoot)
        startRefreshTimer(repoRoot: context.gitContext?.repoRoot)
        return true
    }

    private func cancelTeardown() {
        teardownGeneration &+= 1
    }

    private func scheduleDeferredTeardown() {
        teardownGeneration &+= 1
        let gen = teardownGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownGracePeriod) { [weak self] in
            guard let self, self.teardownGeneration == gen else { return }
            self.performTeardown()
        }
    }

    func cwdChanged(newPath: String, context: TerminalContext) {}

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        // Focusing a tab with no agent must drop the previous tab's agent (handled by
        // the deferred teardown inside `adoptAgent`), or the status bar and section
        // title keep counting up a runtime for an agent that isn't in this tab.
        // Either way the newly focused tab's own config/worktrees still need scanning.
        if !adoptAgent(from: context, trigger: .focusChanged) {
            currentCwd = context.cwd
            scanAgentConfig(cwd: context.cwd)
            scanWorktrees(cwd: context.cwd)
        }
    }

    func checkAvailability() async -> Bool {
        let found = await Task.detached(priority: .utility) {
            AgentBinaryScanner.detectInstalledAgents()
        }.value
        installedAgents = found
        return true
    }

    func pluginDidDeactivate() {
        clearAgentState()
    }

    private func performTeardown() {
        clearAgentState()
        onRequestCycleRerun?()
    }

    private func clearAgentState() {
        cancelTeardown()
        agentStartTime = nil
        activeAgent = nil
        diffStats = []
        activeSessionID = nil
        actions?.setAgentSessionID?(nil)
        lastDiffRepoRoot = nil
        stopRefreshTimer()
        // Invalidate the scan caches without dropping the rows. The config/worktree
        // data is project-scoped, not agent-scoped, so blanking it here would empty
        // the sections while the user is still in the same directory — but keeping
        // the *caches* would make the next focus event short-circuit and never
        // refresh them.
        // `projectRootCache` is deliberately kept: it only memoizes a cwd -> root
        // filesystem walk, whose answer cannot change while the cwd is unchanged.
        configScan.invalidate()
        worktreeScan.invalidate()
    }

    nonisolated static func agentSession(from context: TerminalContext, existingStart: Date?) -> AgentSession? {
        let category = context.processCategory ?? ProcessIcon.category(for: context.processName)
        guard category == "ai" else { return nil }
        let cwd = context.processMetadata["cwd"].flatMap { $0.isEmpty ? nil : $0 } ?? context.cwd
        let startedAt =
            context.processMetadata["started_at"]
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) } ?? existingStart ?? Date()
        guard let kind = AgentKind.infer(processName: context.processName, metadata: context.processMetadata) else {
            guard !context.processName.isEmpty else { return nil }
            return AgentSession(
                kind: .custom,
                displayName: ProcessIcon.displayName(for: context.processName) ?? context.processName,
                processName: context.processName,
                pid: context.processPID,
                cwd: cwd,
                startedAt: startedAt,
                state: AgentRunState(rawValue: context.processMetadata["state"] ?? "") ?? .unknown,
                sessionID: sessionID(from: context.processMetadata),
                transcriptPath: context.processMetadata["transcript_path"],
                model: context.processMetadata["model"],
                mode: context.processMetadata["permission_mode"] ?? context.processMetadata["mode"],
                metadata: context.processMetadata
            )
        }
        return AgentSession(
            kind: kind,
            displayName: kind.displayName,
            processName: context.processName,
            pid: context.processPID,
            cwd: cwd,
            startedAt: startedAt,
            state: AgentRunState(rawValue: context.processMetadata["state"] ?? "") ?? .running,
            sessionID: sessionID(from: context.processMetadata),
            transcriptPath: context.processMetadata["transcript_path"],
            model: context.processMetadata["model"],
            mode: context.processMetadata["permission_mode"] ?? context.processMetadata["mode"],
            metadata: context.processMetadata
        )
    }

    nonisolated private static func sessionID(from metadata: [String: String]) -> String? {
        metadata["session_id"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Session Watching

    // MARK: - Git Diff Stats

    private func refreshDiffStats(repoRoot: String?) {
        guard let root = repoRoot else {
            if !diffStats.isEmpty {
                diffStats = []
                onRequestCycleRerun?()
            }
            lastDiffRepoRoot = nil
            return
        }
        lastDiffRepoRoot = root

        diffDebouncer.schedule { [weak self] in
            self?.runDiffDetection(repoRoot: root)
        }
    }

    private func runDiffDetection(repoRoot: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = detectAgentDiffStats(repoRoot: repoRoot)
            DispatchQueue.main.async {
                guard let self, self.agentStartTime != nil else { return }
                // Compare line counts too, not just paths: the status bar and the
                // Changes section both render +/- numbers, so an edit to an
                // already-listed file has to trigger a refresh.
                let key = { (e: DiffStatEntry) in "\(e.path)|\(e.insertions)|\(e.deletions)" }
                let changed = self.diffStats.map(key) != stats.map(key)
                self.diffStats = stats
                if changed {
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    // MARK: - Refresh Timer

    private func startRefreshTimer(repoRoot: String?) {
        stopRefreshTimer()
        guard let root = repoRoot else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + AgentsConstants.diffRefreshInterval,
            repeating: .seconds(Int(AgentsConstants.diffRefreshInterval)))
        timer.setEventHandler { [weak self] in
            guard let self, self.agentStartTime != nil else {
                self?.stopRefreshTimer()
                return
            }
            self.runDiffDetection(repoRoot: root)
        }
        timer.resume()
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    deinit {
        refreshTimer?.cancel()
    }
}

// MARK: - Utilities

/// Format runtime duration as human-readable string.
func formatAgentRuntime(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let mins = (totalSeconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(mins)m"
    } else if mins > 0 {
        return "\(mins)m"
    } else {
        return "<1m"
    }
}

/// Format date as relative string (e.g., "2h ago", "3d ago").
func formatAgentRelativeDate(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        return "\(Int(interval / 60))m ago"
    } else if interval < 86400 {
        return "\(Int(interval / 3600))h ago"
    } else if interval < 604_800 {
        return "\(Int(interval / 86400))d ago"
    } else {
        return relativeDateFormatter.string(from: date)
    }
}

/// Find project root by walking up from path looking for marker files/dirs.
func findAgentProjectRoot(from path: String, markers: [String]) -> String? {
    let fm = FileManager.default
    var dir = path
    for _ in 0..<AgentsConstants.maxProjectRootDepth {
        for marker in markers {
            let candidate = (dir as NSString).appendingPathComponent(marker)
            if fm.fileExists(atPath: candidate) {
                return dir
            }
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return nil
}

/// Parse skill description from YAML frontmatter in SKILL.md.
func parseAgentSkillDescription(at path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
        let content = String(data: data, encoding: .utf8)
    else { return "" }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var inFrontmatter = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" {
            if inFrontmatter { break }
            inFrontmatter = true
            continue
        }
        if inFrontmatter && trimmed.hasPrefix("description:") {
            return String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

/// Detect git diff stats for changed files in repo.
func detectAgentDiffStats(repoRoot: String) -> [AgentsPlugin.DiffStatEntry] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    task.arguments = ["-C", repoRoot, "diff", "--numstat", "HEAD"]

    // Drain-while-running: `--numstat` on a large working tree easily exceeds the
    // ~64KB pipe buffer, and the read-after-exit shape would deadlock the child.
    guard let result = RemoteExplorer.runProcessCapturing(task, timeout: 10) else {
        debugLog("[Agents] git diff task failed or timed out")
        return []
    }
    guard result.status == 0 else { return [] }
    let output = result.stdout

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let insertions = Int(parts[0]) ?? 0
        let deletions = Int(parts[1]) ?? 0
        let filePath = String(parts[2])
        let fullPath = (repoRoot as NSString).appendingPathComponent(filePath)
        return AgentsPlugin.DiffStatEntry(
            path: filePath,
            insertions: insertions,
            deletions: deletions,
            fullPath: fullPath
        )
    }
}
