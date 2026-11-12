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
/// Each agent CLI plugs in through an `AgentAdapter`; Claude Code is the richest provider.
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
        icon: "asset:robot-head",
        description: "Agent Center for Claude Code, Codex, OpenCode, Copilot, pi, Hermes and other AI CLI sessions",
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
                group: "Agents"),
            PluginManifest.SettingManifest(
                key: "taskSetup", type: .string, label: "Setup command",
                description: "Runs in each new task's worktree before its agent starts.",
                defaultValue: AnyCodableValue(""), options: "agentTaskSetup", group: "Tasks"),
            PluginManifest.SettingManifest(
                key: "worktreeFolder", type: .string, label: "Worktree folder",
                description: "Where new task worktrees go, one folder per repository.",
                defaultValue: AnyCodableValue(""), options: "agentWorktreeFolder", group: "Tasks"),
            PluginManifest.SettingManifest(
                key: "crewActiveWorkspaceOnly", type: .bool, label: "Only list the active workspace's agents",
                description: "Off: every workspace's agents, grouped by workspace, the active one first.",
                defaultValue: AnyCodableValue(false), options: nil, group: "Agents List")
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
    /// One set for the app: the sidebar, menus and palette all read it.
    private(set) static var installedAgents: Set<AgentKind> = Set(AgentKind.allCases).subtracting([.custom])

    /// The installed agents a tab can start, in picker order.
    static var installedKinds: [AgentKind] { AgentKind.taskKinds.filter { installedAgents.contains($0) } }

    private(set) var agentStartTime: Date?
    private(set) var activeAgent: AgentSession?
    var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []
    var worktrees: [ClaudeWorktree] = []
    var agentConfig: AgentConfig = AgentConfig()
    /// Session ID currently being written to (detected via file watching)
    private(set) var activeSessionID: String?

    private var lastDiffRepoRoot: String?
    /// `.agentInboxChanged` / `.agentCrewChanged` observers for the Crew section.
    var crewObservers: [NSObjectProtocol] = []
    var configScan = ScanStamp()
    var worktreeScan = ScanStamp()
    static let scanTTL: TimeInterval = 15

    /// Memoized `findAgentProjectRoot` result, keyed on the cwd that produced it.
    /// Config and worktree scans share it, so a repeated cwd skips the `fileExists` walk.
    private var projectRootCache: (cwd: String, root: String)?

    /// Resolve the project root for `cwd` and hand it to `body` on the main actor.
    /// The walk runs off the main thread only when the cache misses.
    func withProjectRoot(cwd: String, _ body: @escaping @MainActor (String) -> Void) {
        if let cached = projectRootCache, cached.cwd == cwd {
            body(cached.root)
            return
        }
        let markers = Self.projectMarkers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let root = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
            DispatchQueue.main.async {
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
        // Start time, not elapsed seconds: enriched data is part of TerminalContext
        // equality, so a ticking value would rebuild the sidebar every cycle.
        context.setData(AnyHashable(Int(start.timeIntervalSince1970)), forKey: "ai-agent.startedAt")
    }

    /// Launch an agent CLI in a new tab, with `prompt` as its first message when
    /// given. When `resumeSessionID` is set, resume that session instead.
    func startAgent(kind: AgentKind, cwd: String? = nil, resumeSessionID: String? = nil, prompt: String? = nil) {
        let cwd = cwd ?? currentCwd ?? activeAgent?.cwd ?? "~"
        if resumeSessionID == nil, kind != .custom {
            actions?.openTab?(.agent(kind: kind, workingDirectory: cwd, prompt: prompt ?? ""))
            return
        }
        guard let id = resumeSessionID, let command = kind.resumeCommand(sessionID: id) else { return }
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
        Self.installedAgents = found
        WindowManager.shared.menuOwner?.rebuildAgentsMenu()
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
            // Nobody can see the stats while every Boo window is hidden or
            // occluded; skip the git spawn and catch up on the next visible tick.
            guard NSApp.windows.contains(where: { $0.occlusionState.contains(.visible) }) else { return }
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

/// "now", "5m", "3h", "2d", "6w", "1y".
func formatCompactAge(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, now.timeIntervalSince(date))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86_400: return "\(Int(s / 3600))h"
    case ..<(86_400 * 14): return "\(Int(s / 86_400))d"
    case ..<(86_400 * 365): return "\(Int(s / 604_800))w"
    default: return "\(Int(s / 31_536_000))y"
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
    // --no-optional-locks: a plain `git diff` refreshes .git/index, which fires
    // GitService's index watcher and a full git status refresh every poll.
    let args = ["-C", repoRoot, "--no-optional-locks", "diff", "--numstat", "-z", "HEAD"]
    guard let result = Subprocess.run("/usr/bin/git", args, timeout: 10) else {
        debugLog("[Agents] git diff task failed or timed out")
        return []
    }
    guard result.status == 0 else { return [] }
    return parseNumstatZ(result.stdout, repoRoot: repoRoot)
}

/// Parse `git diff --numstat -z`: `ins\tdel\tpath\0`, or for renames
/// `ins\tdel\t\0old\0new\0`. `-z` keeps paths unquoted.
func parseNumstatZ(_ output: String, repoRoot: String) -> [AgentsPlugin.DiffStatEntry] {
    let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var entries: [AgentsPlugin.DiffStatEntry] = []
    var i = 0
    while i < fields.count {
        let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        i += 1
        guard parts.count == 3 else { continue }
        var filePath = String(parts[2])
        if filePath.isEmpty {
            // Rename: old and new path follow as separate fields; keep the new one.
            guard i + 1 < fields.count else { break }
            filePath = fields[i + 1]
            i += 2
        }
        entries.append(
            AgentsPlugin.DiffStatEntry(
                path: filePath,
                insertions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                fullPath: (repoRoot as NSString).appendingPathComponent(filePath)
            ))
    }
    return entries
}
