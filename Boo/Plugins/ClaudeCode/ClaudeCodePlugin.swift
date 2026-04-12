import SwiftUI

/// Built-in plugin for Claude Code AI assistant.
/// Shows sessions, config files, hooks, skills, MCP servers, and changed files.
/// Appears when Claude Code is the foreground process.
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
        icon: "sparkles",
        description: "Claude Code AI assistant",
        when: "process.claude",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 20, template: nil),
        settings: nil
    )

    var prefersOuterScrollView: Bool { false }

    func isVisible(for context: TerminalContext) -> Bool {
        if !AppSettings.shared.isPluginEnabled(pluginID) { return false }
        if agentStartTime != nil { return true }
        guard let clause = whenClause else { return true }
        return WhenClauseEvaluator.evaluate(clause, context: context)
    }

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .cwdChanged, .focusChanged] }

    // MARK: - Cached State

    private(set) var agentStartTime: Date?
    private(set) var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []
    private(set) var sessions: [ClaudeSession] = []
    private(set) var agentConfig: AgentConfig = AgentConfig()

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var lastSessionScanRoot: String?
    private var refreshTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var teardownGeneration: UInt64 = 0
    var teardownGracePeriod: TimeInterval = 2.0

    typealias DiffStatEntry = AgentDiffStatEntry

    static let projectMarkers = [".git", ".claude", "AGENTS.md", "CLAUDE.md"]

    struct ClaudeSession: Identifiable {
        let id: String
        let slug: String?
        let timestamp: Date
        let firstMessage: String
        let path: String
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

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        context.setData(AnyHashable("claude"), forKey: "ai-agent.name")
        if let start = agentStartTime {
            let runtime = Int(Date().timeIntervalSince(start))
            context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
        }
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard agentStartTime != nil else { return nil }
        var text = "Claude"
        if !diffStats.isEmpty {
            let count = diffStats.count
            text += " \u{00B7} \(count) file\(count == 1 ? "" : "s")"
        }
        if let start = agentStartTime {
            let mins = Int(Date().timeIntervalSince(start) / 60)
            if mins > 0 {
                text += " \u{00B7} \(formatAgentRuntime(Date().timeIntervalSince(start)))"
            }
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
        guard agentStartTime != nil else { return nil }
        if let start = agentStartTime {
            let runtime = Date().timeIntervalSince(start)
            return "Claude \u{00B7} \(formatAgentRuntime(runtime))"
        }
        return "Claude"
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard agentStartTime != nil else { return nil }
        let act = actions
        let fontScale = context.fontScale

        return AnyView(
            ClaudeCodeDetailView(
                sessions: sessions,
                diffStats: diffStats,
                agentConfig: agentConfig,
                fontScale: fontScale,
                textColor: Color(nsColor: context.theme.chromeText),
                mutedColor: Color(nsColor: context.theme.chromeMuted),
                accentColor: context.theme.ansiColors.count > 13
                    ? Color(nsColor: context.theme.ansiColors[13])
                    : Color(nsColor: context.theme.accentColor),
                onSessionClicked: { [weak self] session in
                    self?.resumeSession(session)
                },
                onFileClicked: { path in
                    act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                },
                onCopyPath: { path in
                    act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                },
                onReferenceInAI: { path in
                    act?.sendToTerminal?("@\(path) ")
                },
                onPasteSkill: { name in
                    act?.sendToTerminal?("/\(name)")
                }
            )
        )
    }

    // MARK: - Session Resume

    private func resumeSession(_ session: ClaudeSession) {
        actions?.sendToTerminal?("claude --resume \(session.id)\n")
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let isClaude = name.lowercased() == "claude"
        if isClaude {
            cancelTeardown()
            if agentStartTime == nil {
                agentStartTime = Date()
                currentCwd = context.cwd
                scanAgentConfig(cwd: context.cwd)
                scanSessions(cwd: context.cwd)
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
            guard let self = self, self.teardownGeneration == gen else { return }
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
        sessions = []
        agentConfig = AgentConfig()
        lastDiffRepoRoot = nil
        lastConfigScanRoot = nil
        lastSessionScanRoot = nil
        stopRefreshTimer()
    }

    // MARK: - Session Scanning

    private func scanSessions(cwd: String?) {
        guard let cwd = cwd else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: Self.projectMarkers) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentStartTime != nil else { return }
                if self.lastSessionScanRoot == projectRoot { return }
                self.lastSessionScanRoot = projectRoot

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let sessions = Self.detectSessions(projectRoot: projectRoot)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.agentStartTime != nil else { return }
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

        do {
            let entries = try fm.contentsOfDirectory(atPath: projectSessionDir)
            for entry in entries where entry.hasSuffix(".jsonl") {
                let sessionID = (entry as NSString).deletingPathExtension
                let sessionPath = (projectSessionDir as NSString).appendingPathComponent(entry)

                if let session = parseSessionFile(path: sessionPath, sessionID: sessionID) {
                    sessions.append(session)
                }
            }
        } catch {
            return []
        }

        // Sort by timestamp descending (most recent first)
        return sessions.sorted { $0.timestamp > $1.timestamp }
    }

    nonisolated private static func parseSessionFile(path: String, sessionID: String) -> ClaudeSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var slug: String?
        var timestamp: Date?
        var firstMessage: String?

        guard let data = try? handle.readToEnd(),
            let content = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = content.components(separatedBy: "\n")
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines.prefix(50) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if slug == nil, let s = json["slug"] as? String {
                slug = s
            }

            if timestamp == nil,
                let type = json["type"] as? String, type == "user",
                let ts = json["timestamp"] as? String,
                let date = dateFormatter.date(from: ts)
            {
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

            if slug != nil && timestamp != nil && firstMessage != nil {
                break
            }
        }

        guard let ts = timestamp else { return nil }

        return ClaudeSession(
            id: sessionID,
            slug: slug,
            timestamp: ts,
            firstMessage: firstMessage ?? "",
            path: path
        )
    }

    // MARK: - Agent Config Scan

    private func scanAgentConfig(cwd: String?) {
        guard let cwd = cwd else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: Self.projectMarkers) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentStartTime != nil else { return }
                if self.lastConfigScanRoot == projectRoot { return }
                self.lastConfigScanRoot = projectRoot

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let config = Self.detectAgentConfig(cwd: cwd)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.agentStartTime != nil else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func runDiffDetection(repoRoot: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = detectAgentDiffStats(repoRoot: repoRoot)
            DispatchQueue.main.async {
                guard let self = self, self.agentStartTime != nil else { return }
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
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.agentStartTime != nil else {
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
