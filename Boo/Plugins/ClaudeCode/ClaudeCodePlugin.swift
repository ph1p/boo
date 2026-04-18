import SwiftUI

// MARK: - Constants

private enum ClaudeCodeConstants {
    /// Maximum directory depth when walking up to find project root
    static let maxProjectRootDepth = 20
    /// Time threshold (seconds) to consider a session file as recently modified
    static let recentlyModifiedThreshold: TimeInterval = 5
    /// Time threshold (seconds) to consider a session as currently active
    static let activeSessionThreshold: TimeInterval = 30
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

/// Built-in plugin for Claude Code AI assistant.
/// Shows sessions, config files, hooks, skills, MCP servers, and changed files.
/// Always visible when enabled; shows active agent status when running.
@MainActor
final class ClaudeCodePlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "claude-code",
        name: "Claude Code",
        version: "1.0.0",
        icon: "asset:claude-icon",
        description: "Claude Code AI assistant",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 20, template: nil),
        settings: nil
    )

    var prefersOuterScrollView: Bool { true }

    func isVisible(for context: TerminalContext) -> Bool {
        AppSettings.shared.isPluginEnabled(pluginID)
    }

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .cwdChanged, .focusChanged] }

    // MARK: - Cached State

    private(set) var agentStartTime: Date?
    private(set) var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []
    private(set) var sessions: [ClaudeSession] = []
    private(set) var worktrees: [ClaudeWorktree] = []
    private(set) var agentConfig: AgentConfig = AgentConfig()
    private(set) var claudeSettings: ClaudeSettings = ClaudeSettings()
    /// Session ID currently being written to (detected via file watching)
    private(set) var activeSessionID: String?

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var lastSessionScanRoot: String?
    private var lastWorktreeScanRoot: String?
    private var refreshTimer: DispatchSourceTimer?
    private var sessionWatcher: DispatchSourceFileSystemObject?
    private var sessionDirPath: String?
    private var debounceWork: DispatchWorkItem?
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

    struct ClaudeSession: Identifiable {
        let id: String
        let slug: String?
        let timestamp: Date
        let firstMessage: String
        let path: String
        /// Number of messages in session (user + assistant turns)
        var messageCount: Int = 0
        /// Total tokens used (if available from session file)
        var totalTokens: Int = 0
        /// Last activity timestamp
        var lastActivity: Date?
        /// Whether this session is currently active in a terminal
        var isActive: Bool = false
    }

    /// A Claude Code git worktree (isolated branch for parallel work).
    struct ClaudeWorktree: Identifiable {
        let id: String  // The slug/name (e.g., "feature-foo")
        let path: String  // Full path to worktree directory
        let branch: String  // Git branch name (e.g., "worktree-feature-foo")
        let headCommit: String?  // Current HEAD SHA (short)
        let created: Date?  // Creation timestamp from directory
    }

    struct AgentConfig {
        var configFiles: [ConfigFile] = []
        var hooks: [HookEntry] = []
        var skills: [SkillEntry] = []
        var mcpServers: [String] = []

        struct ConfigFile: Identifiable {
            let id = UUID()
            let name: String
            let path: String
            let icon: String
            let scope: String
        }

        struct HookEntry: Identifiable {
            let id = UUID()
            let event: String
            let command: String
        }

        struct SkillEntry: Identifiable {
            let id = UUID()
            let name: String
            let description: String
            let path: String
        }
    }

    struct ClaudeSettings {
        var model: String = ""
        var effortLevel: String = "medium"
        var alwaysThinkingEnabled: Bool = false
        var voiceEnabled: Bool = false
        var enabledPlugins: [String] = []

        /// Display-friendly model name (strips date suffix)
        var modelDisplayName: String {
            // claude-opus-4-5-20251101 -> claude-opus-4-5
            let parts = model.split(separator: "-")
            if parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
                return parts.dropLast().joined(separator: "-")
            }
            return model.isEmpty ? "default" : model
        }

        static let settingsPath: String = {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(".claude/settings.json")
        }()
    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        guard let start = agentStartTime else { return }
        context.setData(AnyHashable("claude"), forKey: "ai-agent.name")
        let runtime = Int(Date().timeIntervalSince(start))
        context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let start = agentStartTime else { return nil }
        var text = "Claude"
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
            accessibilityLabel: "Claude Code: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard let start = agentStartTime else { return nil }
        let runtime = Date().timeIntervalSince(start)
        return "Claude \u{00B7} \(formatAgentRuntime(runtime))"
    }

    // MARK: - Sidebar Tab (multi-section)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }

        // If no agent running, scan config/sessions/worktrees based on current terminal CWD
        let isAgentActive = agentStartTime != nil
        if !isAgentActive && currentCwd != context.terminal.cwd {
            scanAgentConfig(cwd: context.terminal.cwd)
            scanSessions(cwd: context.terminal.cwd)
            scanWorktrees(cwd: context.terminal.cwd)
        }

        // Load settings on first access if not loaded yet
        if claudeSettings.model.isEmpty {
            loadClaudeSettings()
        }

        let act = actions
        let fontScale = context.fontScale
        let textColor = Color(nsColor: context.theme.chromeText)
        let mutedColor = Color(nsColor: context.theme.chromeMuted)
        let accentColor =
            context.theme.ansiColors.count > 13
            ? Color(nsColor: context.theme.ansiColors[13])
            : Color(nsColor: context.theme.accentColor)

        var sections: [SidebarSection] = []

        // Active agent status section (only when running)
        if isAgentActive {
            // Find active session details
            let activeSession = sessions.first { $0.id == activeSessionID }

            let statusSection = SidebarSection(
                id: "claude-code.status",
                name: "Active Session",
                icon: "bolt.fill",
                content: AnyView(
                    ClaudeActiveSessionView(
                        agentStartTime: agentStartTime,
                        activeSession: activeSession,
                        activeSessionID: activeSessionID,
                        diffStats: diffStats,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor
                    )
                ),
                prefersOuterScrollView: false,
                generation: UInt64(agentStartTime?.timeIntervalSince1970 ?? 0)
                    &+ UInt64(bitPattern: Int64(activeSessionID?.hashValue ?? 0))
            )
            sections.append(statusSection)
        }

        // Sessions section
        if !sessions.isEmpty {
            let sessionsSection = SidebarSection(
                id: "claude-code.sessions",
                name: "Sessions (\(sessions.count))",
                icon: "bubble.left.and.bubble.right",
                content: AnyView(
                    ClaudeSessionsView(
                        sessions: sessions,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onSessionClicked: { [weak self] session in
                            self?.resumeSession(session)
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        }
                    )),
                prefersOuterScrollView: true,
                generation: UInt64(sessions.count))
            sections.append(sessionsSection)
        }

        // Worktrees section
        if !worktrees.isEmpty {
            let worktreesSection = SidebarSection(
                id: "claude-code.worktrees",
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
                generation: UInt64(worktrees.count))
            sections.append(worktreesSection)
        }

        // Config section
        if !agentConfig.configFiles.isEmpty {
            let configSection = SidebarSection(
                id: "claude-code.config",
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
                generation: UInt64(agentConfig.configFiles.count))
            sections.append(configSection)
        }

        // Hooks section
        if !agentConfig.hooks.isEmpty {
            let hooksSection = SidebarSection(
                id: "claude-code.hooks",
                name: "Hooks (\(agentConfig.hooks.count))",
                icon: "arrow.triangle.turn.up.right.diamond",
                content: AnyView(
                    ClaudeHooksView(
                        hooks: agentConfig.hooks,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor
                    )),
                prefersOuterScrollView: true,
                generation: UInt64(agentConfig.hooks.count))
            sections.append(hooksSection)
        }

        // MCP Servers section
        if !agentConfig.mcpServers.isEmpty {
            let mcpSection = SidebarSection(
                id: "claude-code.mcp",
                name: "MCP Servers (\(agentConfig.mcpServers.count))",
                icon: "server.rack",
                content: AnyView(
                    ClaudeMCPView(
                        mcpServers: agentConfig.mcpServers,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor
                    )),
                prefersOuterScrollView: true,
                generation: UInt64(agentConfig.mcpServers.count))
            sections.append(mcpSection)
        }

        // Skills section
        if !agentConfig.skills.isEmpty {
            let skillsSection = SidebarSection(
                id: "claude-code.skills",
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
                generation: UInt64(agentConfig.skills.count))
            sections.append(skillsSection)
        }

        // Changes section
        if !diffStats.isEmpty {
            let ins = diffStats.reduce(0) { $0 + $1.insertions }
            let del = diffStats.reduce(0) { $0 + $1.deletions }
            let changesSection = SidebarSection(
                id: "claude-code.changes",
                name: "Changes (\(diffStats.count)) +\(ins) -\(del)",
                icon: "doc.badge.plus",
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
                generation: UInt64(diffStats.count))
            sections.append(changesSection)
        }

        // Settings section (always show if we have settings loaded)
        if !claudeSettings.model.isEmpty {
            let settingsSection = SidebarSection(
                id: "claude-code.settings",
                name: "Settings",
                icon: "gearshape",
                content: AnyView(
                    ClaudeSettingsView(
                        settings: claudeSettings,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onSettingChanged: { [weak self] key, value in
                            self?.updateClaudeSetting(key: key, value: value)
                        },
                        onOpenSettings: {
                            act?.handle(
                                DSLAction(type: "open", path: ClaudeSettings.settingsPath, command: nil, text: nil))
                        }
                    )),
                prefersOuterScrollView: false,
                generation: UInt64(
                    bitPattern: Int64(claudeSettings.model.hashValue &+ claudeSettings.effortLevel.hashValue)))
            sections.append(settingsSection)
        }

        // If no sections (no agent, no sessions, no config), show getting started
        if sections.isEmpty {
            let emptySection = SidebarSection(
                id: "claude-code",
                name: "Claude Code",
                icon: "sparkles",
                content: AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Claude Code sessions found")
                            .font(fontScale.font(.base))
                            .foregroundColor(textColor)
                        Text("Run `claude` in a terminal to start")
                            .font(fontScale.font(.sm))
                            .foregroundColor(mutedColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                ),
                prefersOuterScrollView: false,
                generation: 0)
            sections.append(emptySection)
        }

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: sections)
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }

    // MARK: - Session Resume

    private func resumeSession(_ session: ClaudeSession) {
        let cwd = currentCwd ?? "~"
        actions?.openTab?(.terminalWithCommand(workingDirectory: cwd, command: "claude --resume \(session.id)"))
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let isClaude = name.lowercased() == "claude"
        if isClaude {
            cancelTeardown()
            if agentStartTime == nil {
                agentStartTime = Date()
                currentCwd = context.cwd
                onRequestCycleRerun?()  // Immediate update for "Active" status
                scanAgentConfig(cwd: context.cwd)
                scanSessions(cwd: context.cwd)
                scanWorktrees(cwd: context.cwd)
                startSessionWatcher(cwd: context.cwd)
            }
            refreshDiffStats(repoRoot: context.gitContext?.repoRoot)
            startRefreshTimer(repoRoot: context.gitContext?.repoRoot)
        } else if agentStartTime != nil {
            scheduleDeferredTeardown()
        }
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
        let isClaude = context.processName.lowercased() == "claude"
        if isClaude {
            cancelTeardown()
            if agentStartTime == nil {
                agentStartTime = Date()
                currentCwd = context.cwd
                scanAgentConfig(cwd: context.cwd)
                scanSessions(cwd: context.cwd)
                scanWorktrees(cwd: context.cwd)
            }
            refreshDiffStats(repoRoot: context.gitContext?.repoRoot)
            startRefreshTimer(repoRoot: context.gitContext?.repoRoot)
        }
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
        diffStats = []
        activeSessionID = nil
        // Clear session ID from tab state when agent exits
        actions?.setAgentSessionID?(nil)
        // Update sessions to mark none as active
        for i in sessions.indices {
            sessions[i].isActive = false
        }
        // Don't clear sessions/agentConfig - they're project-scoped, not agent-scoped.
        // Clearing them on deactivate causes "No sessions found" on tab switch back.
        lastDiffRepoRoot = nil
        stopRefreshTimer()
        stopSessionWatcher()
    }

    // MARK: - Session Watching

    /// Start watching the Claude session directory for file changes to detect active session.
    private func startSessionWatcher(cwd: String?) {
        stopSessionWatcher()
        guard let cwd = cwd else { return }

        let markers = Self.projectMarkers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            let projectDirName = projectRoot.replacingOccurrences(of: "/", with: "-")
            let sessionDir = (home as NSString).appendingPathComponent(".claude/projects/\(projectDirName)")

            guard fm.fileExists(atPath: sessionDir) else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessionDirPath = sessionDir
                self.watchSessionDirectory(sessionDir)
            }
        }
    }

    private func watchSessionDirectory(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.detectActiveSession()
        }

        source.setCancelHandler {
            close(fd)
        }

        sessionWatcher = source
        source.resume()

        // Initial detection
        detectActiveSession()
    }

    private func stopSessionWatcher() {
        sessionWatcher?.cancel()
        sessionWatcher = nil
        sessionDirPath = nil
    }

    /// Find which session file was most recently modified (the active one).
    private func detectActiveSession() {
        guard let sessionDir = sessionDirPath else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var mostRecentID: String?
            var mostRecentTime: Date?

            guard let entries = try? fm.contentsOfDirectory(atPath: sessionDir) else { return }

            for entry in entries where entry.hasSuffix(".jsonl") {
                let path = (sessionDir as NSString).appendingPathComponent(entry)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                    let modTime = attrs[.modificationDate] as? Date
                else { continue }

                // Only consider recently modified files
                if Date().timeIntervalSince(modTime) < ClaudeCodeConstants.recentlyModifiedThreshold {
                    if mostRecentTime.map({ modTime > $0 }) ?? true {
                        mostRecentTime = modTime
                        mostRecentID = (entry as NSString).deletingPathExtension
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.activeSessionID != mostRecentID {
                    self.activeSessionID = mostRecentID
                    // Save to tab state so we know which session belongs to this tab
                    self.actions?.setAgentSessionID?(mostRecentID)
                    // Update sessions list with active state
                    for i in self.sessions.indices {
                        self.sessions[i].isActive = (self.sessions[i].id == mostRecentID)
                    }
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    // MARK: - Session Scanning

    private func scanSessions(cwd: String?) {
        guard let cwd = cwd else { return }

        let markers = Self.projectMarkers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.lastSessionScanRoot == projectRoot { return }
                self.lastSessionScanRoot = projectRoot
                self.currentCwd = cwd

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let sessions = Self.detectSessions(projectRoot: projectRoot)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.sessions = sessions
                        self.onRequestCycleRerun?()
                    }
                }
            }
        }
    }

    nonisolated static func detectSessions(projectRoot: String) -> [ClaudeSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let claudeProjectsDir = (home as NSString).appendingPathComponent(".claude/projects")

        // Convert project path to Claude's folder naming: /Users/foo/bar -> -Users-foo-bar
        let projectDirName = projectRoot.replacingOccurrences(of: "/", with: "-")
        let projectSessionDir = (claudeProjectsDir as NSString).appendingPathComponent(projectDirName)

        guard fm.fileExists(atPath: projectSessionDir) else { return [] }

        var sessions: [ClaudeSession] = []

        // Track which session file was modified most recently (likely active)
        var mostRecentModTime: Date?
        var mostRecentSessionID: String?

        do {
            let entries = try fm.contentsOfDirectory(atPath: projectSessionDir)
            for entry in entries where entry.hasSuffix(".jsonl") {
                let sessionID = (entry as NSString).deletingPathExtension
                let sessionPath = (projectSessionDir as NSString).appendingPathComponent(entry)

                // Check file modification time to detect active session
                if let attrs = try? fm.attributesOfItem(atPath: sessionPath),
                    let modDate = attrs[.modificationDate] as? Date
                {
                    if mostRecentModTime.map({ modDate > $0 }) ?? true {
                        mostRecentModTime = modDate
                        mostRecentSessionID = sessionID
                    }
                }

                if let session = parseSessionFile(path: sessionPath, sessionID: sessionID) {
                    sessions.append(session)
                }
            }
        } catch {
            debugLog("[ClaudeCode] Failed to enumerate session directory: \(error)")
            return []
        }

        // Mark most recently modified session as active (if modified in last 30 seconds)
        if let activeID = mostRecentSessionID,
            let modTime = mostRecentModTime,
            Date().timeIntervalSince(modTime) < ClaudeCodeConstants.activeSessionThreshold
        {
            if let idx = sessions.firstIndex(where: { $0.id == activeID }) {
                sessions[idx].isActive = true
            }
        }

        // Sort: active first, then by last activity descending
        return sessions.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            let aTime = a.lastActivity ?? a.timestamp
            let bTime = b.lastActivity ?? b.timestamp
            return aTime > bTime
        }
    }

    nonisolated private static func parseSessionFile(path: String, sessionID: String) -> ClaudeSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var slug: String?
        var timestamp: Date?
        var lastActivity: Date?
        var firstMessage: String?
        var messageCount = 0
        var totalTokens = 0

        guard let data = try? handle.readToEnd(),
            let content = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = content.components(separatedBy: "\n")
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if slug == nil, let s = json["slug"] as? String {
                slug = s
            }

            // Count messages and track timestamps
            if let type = json["type"] as? String,
                let ts = json["timestamp"] as? String,
                let date = dateFormatter.date(from: ts)
            {
                if type == "user" || type == "assistant" {
                    messageCount += 1
                    lastActivity = date
                }

                // Get first user message for preview
                if timestamp == nil && type == "user" {
                    timestamp = date
                    if let msg = json["message"] as? [String: Any],
                        let content = msg["content"] as? String
                    {
                        firstMessage = String(content.prefix(100))
                    } else if let msg = json["message"] as? [String: Any],
                        let contentArray = msg["content"] as? [[String: Any]],
                        let first = contentArray.first,
                        let text = first["content"] as? String
                    {
                        firstMessage = String(text.prefix(100))
                    }
                }
            }

            // Sum up token usage
            if let usage = json["usage"] as? [String: Any] {
                if let input = usage["input_tokens"] as? Int {
                    totalTokens += input
                }
                if let output = usage["output_tokens"] as? Int {
                    totalTokens += output
                }
            }
        }

        guard let ts = timestamp else { return nil }

        return ClaudeSession(
            id: sessionID,
            slug: slug,
            timestamp: ts,
            firstMessage: firstMessage ?? "",
            path: path,
            messageCount: messageCount,
            totalTokens: totalTokens,
            lastActivity: lastActivity
        )
    }

    // MARK: - Worktree Scanning

    private func scanWorktrees(cwd: String?) {
        guard let cwd = cwd else { return }

        let markers = Self.projectMarkers
        let projectRoot = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
        guard lastWorktreeScanRoot != projectRoot else { return }
        lastWorktreeScanRoot = projectRoot

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let worktrees = Self.detectWorktrees(projectRoot: projectRoot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.worktrees = worktrees
                self.onRequestCycleRerun?()
            }
        }
    }

    nonisolated static func detectWorktrees(projectRoot: String) -> [ClaudeWorktree] {
        let fm = FileManager.default
        let worktreesDir = (projectRoot as NSString).appendingPathComponent(".claude/worktrees")

        guard fm.fileExists(atPath: worktreesDir) else { return [] }

        var worktrees: [ClaudeWorktree] = []

        do {
            let entries = try fm.contentsOfDirectory(atPath: worktreesDir)
            for entry in entries {
                let worktreePath = (worktreesDir as NSString).appendingPathComponent(entry)

                // Check if it's a directory (worktree)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: worktreePath, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                // Get branch name from the .git file or HEAD
                let branch = getWorktreeBranch(at: worktreePath) ?? "worktree-\(entry)"

                // Get HEAD commit (short SHA)
                let headCommit = getWorktreeHead(at: worktreePath)

                // Get creation date from directory
                let created: Date? = {
                    if let attrs = try? fm.attributesOfItem(atPath: worktreePath),
                        let date = attrs[.creationDate] as? Date
                    {
                        return date
                    }
                    return nil
                }()

                worktrees.append(
                    ClaudeWorktree(
                        id: entry,
                        path: worktreePath,
                        branch: branch,
                        headCommit: headCommit,
                        created: created
                    ))
            }
        } catch {
            debugLog("[ClaudeCode] Failed to enumerate worktrees directory: \(error)")
            return []
        }

        // Sort by creation date, newest first
        return worktrees.sorted { a, b in
            let aDate = a.created ?? .distantPast
            let bDate = b.created ?? .distantPast
            return aDate > bDate
        }
    }

    /// Get the branch name for a worktree by reading its HEAD reference.
    nonisolated private static func getWorktreeBranch(at path: String) -> String? {
        // Worktrees have a .git file pointing to the main repo's .git/worktrees/<name>
        let gitFilePath = (path as NSString).appendingPathComponent(".git")

        // Check if .git is a file (worktree) or directory (main repo)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: gitFilePath, isDirectory: &isDir), !isDir.boolValue {
            // It's a worktree - read the gitdir pointer
            guard let content = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
                return nil
            }
            // Format: "gitdir: /path/to/repo/.git/worktrees/<name>"
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("gitdir: ") else { return nil }
            let gitDir = String(trimmed.dropFirst("gitdir: ".count))

            // Read HEAD from the worktree's git directory
            let worktreeHeadPath = (gitDir as NSString).appendingPathComponent("HEAD")
            guard let headContent = try? String(contentsOfFile: worktreeHeadPath, encoding: .utf8) else {
                return nil
            }

            let headTrimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)
            // Format: "ref: refs/heads/<branch>"
            if headTrimmed.hasPrefix("ref: refs/heads/") {
                return String(headTrimmed.dropFirst("ref: refs/heads/".count))
            }
        }

        return nil
    }

    /// Get the short HEAD SHA for a worktree.
    nonisolated private static func getWorktreeHead(at path: String) -> String? {
        let gitFilePath = (path as NSString).appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: gitFilePath, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }

        guard let content = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else { return nil }
        let gitDir = String(trimmed.dropFirst("gitdir: ".count))

        let worktreeHeadPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let headContent = try? String(contentsOfFile: worktreeHeadPath, encoding: .utf8) else {
            return nil
        }

        let headTrimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it's a ref, resolve it
        if headTrimmed.hasPrefix("ref: ") {
            let refPath = String(headTrimmed.dropFirst("ref: ".count))
            // The ref is relative to the main repo's .git, not the worktree's gitdir
            // Go up from .git/worktrees/<name> to .git
            let mainGitDir = ((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let fullRefPath = (mainGitDir as NSString).appendingPathComponent(refPath)
            if let sha = try? String(contentsOfFile: fullRefPath, encoding: .utf8) {
                return String(sha.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
            }
        } else if headTrimmed.count >= 7 {
            // Detached HEAD - it's a SHA
            return String(headTrimmed.prefix(7))
        }

        return nil
    }

    private func openWorktree(_ worktree: ClaudeWorktree) {
        // Open the worktree directory in a new tab
        actions?.openDirectoryInNewTab?(worktree.path)
    }

    // MARK: - Agent Config Scan

    private func scanAgentConfig(cwd: String?) {
        guard let cwd = cwd else { return }

        let markers = Self.projectMarkers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: markers) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.lastConfigScanRoot == projectRoot { return }
                self.lastConfigScanRoot = projectRoot
                self.currentCwd = cwd

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let config = Self.detectAgentConfig(cwd: cwd)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.agentConfig = config
                        self.onRequestCycleRerun?()
                    }
                }
            }
        }
    }

    nonisolated static func detectAgentConfig(cwd: String) -> AgentConfig {
        let fm = FileManager.default
        var config = AgentConfig()
        let home = fm.homeDirectoryForCurrentUser.path
        let projectRoot = findAgentProjectRoot(from: cwd, markers: projectMarkers) ?? cwd

        checkFile(
            fm: fm, root: projectRoot, rel: ".claude/CLAUDE.md", name: "CLAUDE.md", icon: "doc.text",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "CLAUDE.md", name: "CLAUDE.md", icon: "doc.text",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".claude/settings.json", name: "Settings", icon: "gearshape",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".claude/settings.local.json", name: "Local Settings",
            icon: "gearshape", scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".claude/mcp.json", name: "MCP Servers", icon: "server.rack",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: home, rel: ".claude/settings.json", name: "Global Settings", icon: "gearshape",
            scope: "global", into: &config)
        checkFile(
            fm: fm, root: home, rel: ".claude.json", name: "Global MCP", icon: "server.rack", scope: "global",
            into: &config)
        checkFile(
            fm: fm, root: home, rel: ".claude/CLAUDE.md", name: "Global CLAUDE.md", icon: "doc.text",
            scope: "global", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "AGENTS.md", name: "AGENTS.md", icon: "person.2", scope: "project",
            into: &config)

        let skillsDir = (projectRoot as NSString).appendingPathComponent(".claude/skills")
        if let entries = try? fm.contentsOfDirectory(atPath: skillsDir) {
            for entry in entries.sorted() {
                let skillMd = (skillsDir as NSString).appendingPathComponent("\(entry)/SKILL.md")
                if fm.fileExists(atPath: skillMd) {
                    let desc = parseAgentSkillDescription(at: skillMd)
                    config.skills.append(
                        AgentConfig.SkillEntry(name: entry, description: desc, path: skillMd))
                }
            }
        }
        let globalSkillsDir = (home as NSString).appendingPathComponent(".claude/skills")
        if let entries = try? fm.contentsOfDirectory(atPath: globalSkillsDir) {
            let projectSkillNames = Set(config.skills.map(\.name))
            for entry in entries.sorted() {
                guard !projectSkillNames.contains(entry) else { continue }
                let skillMd = (globalSkillsDir as NSString).appendingPathComponent("\(entry)/SKILL.md")
                if fm.fileExists(atPath: skillMd) {
                    let desc = parseAgentSkillDescription(at: skillMd)
                    config.skills.append(
                        AgentConfig.SkillEntry(name: entry, description: desc, path: skillMd))
                }
            }
        }

        scanClaudeHooks(fm: fm, root: projectRoot, home: home, into: &config)
        scanClaudeMCP(fm: fm, root: projectRoot, home: home, into: &config)

        return config
    }

    nonisolated private static func checkFile(
        fm: FileManager, root: String, rel: String, name: String,
        icon: String, scope: String, into config: inout AgentConfig
    ) {
        let fullPath = (root as NSString).appendingPathComponent(rel)
        if fm.fileExists(atPath: fullPath) {
            if !config.configFiles.contains(where: { $0.path == fullPath }) {
                config.configFiles.append(
                    AgentConfig.ConfigFile(name: name, path: fullPath, icon: icon, scope: scope))
            }
        }
    }

    nonisolated private static func scanClaudeHooks(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        for settingsPath in [
            (root as NSString).appendingPathComponent(".claude/settings.json"),
            (root as NSString).appendingPathComponent(".claude/settings.local.json"),
            (home as NSString).appendingPathComponent(".claude/settings.json")
        ] {
            guard let data = fm.contents(atPath: settingsPath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let hooks = json["hooks"] as? [String: Any]
            else { continue }

            for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
                guard let entries = value as? [[String: Any]] else { continue }
                for entry in entries {
                    if let hookList = entry["hooks"] as? [[String: Any]] {
                        for hook in hookList {
                            if let cmd = hook["command"] as? String {
                                let shortCmd = (cmd as NSString).lastPathComponent
                                config.hooks.append(AgentConfig.HookEntry(event: event, command: shortCmd))
                            }
                        }
                    }
                }
            }
            break
        }
    }

    nonisolated private static func scanClaudeMCP(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        for mcpPath in [
            (root as NSString).appendingPathComponent(".claude/mcp.json"),
            (home as NSString).appendingPathComponent(".claude.json")
        ] {
            guard let data = fm.contents(atPath: mcpPath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let servers = json["mcpServers"] as? [String: Any]
            else { continue }

            for name in servers.keys.sorted() {
                if !config.mcpServers.contains(name) {
                    config.mcpServers.append(name)
                }
            }
        }
    }

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

        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDiffDetection(repoRoot: root)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeCodeConstants.diffDebounceDelay, execute: work)
    }

    private func runDiffDetection(repoRoot: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = detectAgentDiffStats(repoRoot: repoRoot)
            DispatchQueue.main.async {
                guard let self, self.agentStartTime != nil else { return }
                let oldPaths = self.diffStats.map(\.path)
                let newPaths = stats.map(\.path)
                self.diffStats = stats
                if oldPaths != newPaths {
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
            deadline: .now() + ClaudeCodeConstants.diffRefreshInterval,
            repeating: .seconds(Int(ClaudeCodeConstants.diffRefreshInterval)))
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

    // MARK: - Claude Settings

    private func loadClaudeSettings() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let settings = Self.parseClaudeSettings()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.claudeSettings = settings
                self.onRequestCycleRerun?()
            }
        }
    }

    nonisolated static func parseClaudeSettings() -> ClaudeSettings {
        let fm = FileManager.default
        let path = ClaudeSettings.settingsPath

        guard let data = fm.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ClaudeSettings()
        }

        var settings = ClaudeSettings()
        settings.model = json["model"] as? String ?? ""
        settings.effortLevel = json["effortLevel"] as? String ?? "medium"
        settings.alwaysThinkingEnabled = json["alwaysThinkingEnabled"] as? Bool ?? false
        settings.voiceEnabled = json["voiceEnabled"] as? Bool ?? false

        if let plugins = json["enabledPlugins"] as? [String: Bool] {
            settings.enabledPlugins = plugins.filter { $0.value }.map(\.key).sorted()
        }

        return settings
    }

    func updateClaudeSetting(key: String, value: Any) {
        nonisolated(unsafe) let capturedValue = value
        DispatchQueue.global(qos: .utility).async { [weak self] in
        let value = capturedValue
            let fm = FileManager.default
            let path = ClaudeSettings.settingsPath

            // Read existing settings
            var json: [String: Any] = [:]
            if let data = fm.contents(atPath: path),
                let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                json = existing
            }

            // Update the value
            json[key] = value

            // Write back
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }

            // Reload settings
            DispatchQueue.main.async { [weak self] in
                self?.loadClaudeSettings()
            }
        }
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
    for _ in 0..<ClaudeCodeConstants.maxProjectRootDepth {
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
func detectAgentDiffStats(repoRoot: String) -> [ClaudeCodePlugin.DiffStatEntry] {
    let task = Process()
    task.launchPath = "/usr/bin/git"
    task.arguments = ["-C", repoRoot, "diff", "--numstat", "HEAD"]
    task.standardError = FileHandle.nullDevice

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
    } catch {
        debugLog("[ClaudeCode] git diff task failed: \(error)")
        return []
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return [] }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let insertions = Int(parts[0]) ?? 0
        let deletions = Int(parts[1]) ?? 0
        let filePath = String(parts[2])
        let fullPath = (repoRoot as NSString).appendingPathComponent(filePath)
        return ClaudeCodePlugin.DiffStatEntry(
            path: filePath,
            insertions: insertions,
            deletions: deletions,
            fullPath: fullPath
        )
    }
}
