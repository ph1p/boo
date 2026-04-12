import SwiftUI

/// Built-in plugin for OpenCode AI assistant.
/// Shows sessions, config files, skills, MCP servers, and changed files.
/// Appears when OpenCode is the foreground process.
@MainActor
final class OpenCodePlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "opencode",
        name: "OpenCode",
        version: "1.0.0",
        icon: "sparkles",
        description: "OpenCode AI assistant",
        when: "process.opencode || process.oc",
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
    private(set) var sessions: [OpenCodeSession] = []
    private(set) var agentConfig: AgentConfig = AgentConfig()

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var lastSessionScanRoot: String?
    private var refreshTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var teardownGeneration: UInt64 = 0
    var teardownGracePeriod: TimeInterval = 2.0

    typealias DiffStatEntry = AgentDiffStatEntry

    static let projectMarkers = [".git", ".opencode", "opencode.json", "AGENTS.md"]

    struct OpenCodeSession: Identifiable {
        let id: String
        let slug: String?
        let timestamp: Date
        let title: String?
        let path: String
    }

    struct AgentConfig {
        var configFiles: [ConfigFile] = []
        var skills: [SkillEntry] = []
        var mcpServers: [String] = []

        struct ConfigFile: Identifiable {
            let id = UUID()
            let name: String
            let path: String
            let icon: String
            let scope: String
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
        context.setData(AnyHashable("opencode"), forKey: "ai-agent.name")
        if let start = agentStartTime {
            let runtime = Int(Date().timeIntervalSince(start))
            context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
        }
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard agentStartTime != nil else { return nil }
        var text = "OpenCode"
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
            accessibilityLabel: "OpenCode: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard agentStartTime != nil else { return nil }
        if let start = agentStartTime {
            let runtime = Date().timeIntervalSince(start)
            return "OpenCode \u{00B7} \(formatAgentRuntime(runtime))"
        }
        return "OpenCode"
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard agentStartTime != nil else { return nil }
        let act = actions
        let fontScale = context.fontScale

        return AnyView(
            OpenCodeDetailView(
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
                onPasteSkill: { name in
                    act?.sendToTerminal?("/\(name)")
                }
            )
        )
    }

    // MARK: - Session Resume

    private func resumeSession(_ session: OpenCodeSession) {
        actions?.sendToTerminal?("opencode --resume \(session.id)\n")
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let lower = name.lowercased()
        let isOpenCode = lower == "opencode" || lower == "oc"
        if isOpenCode {
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
        let lower = context.processName.lowercased()
        let isOpenCode = lower == "opencode" || lower == "oc"
        if isOpenCode {
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

    nonisolated static func detectSessions(projectRoot: String) -> [OpenCodeSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let storageDir = (home as NSString).appendingPathComponent(".local/share/opencode/storage")
        let projectsDir = (storageDir as NSString).appendingPathComponent("project")
        let sessionsDir = (storageDir as NSString).appendingPathComponent("session")

        guard let projectFiles = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var projectHash: String?
        for file in projectFiles where file.hasSuffix(".json") {
            let filePath = (projectsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: filePath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let worktree = json["worktree"] as? String,
                worktree == projectRoot
            else { continue }
            projectHash = (file as NSString).deletingPathExtension
            break
        }

        guard let hash = projectHash else { return [] }

        let projectSessionsDir = (sessionsDir as NSString).appendingPathComponent(hash)
        guard let sessionFiles = try? fm.contentsOfDirectory(atPath: projectSessionsDir) else { return [] }

        var sessions: [OpenCodeSession] = []

        for file in sessionFiles where file.hasSuffix(".json") {
            let filePath = (projectSessionsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: filePath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionID = json["id"] as? String,
                let time = json["time"] as? [String: Any],
                let createdMs = time["created"] as? Double
            else { continue }

            let timestamp = Date(timeIntervalSince1970: createdMs / 1000)
            let slug = json["slug"] as? String
            let title = json["title"] as? String

            sessions.append(
                OpenCodeSession(
                    id: sessionID,
                    slug: slug,
                    timestamp: timestamp,
                    title: title,
                    path: filePath
                ))
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }
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
        let projectRoot = findAgentProjectRoot(from: cwd, markers: Self.projectMarkers) ?? cwd
        let xdgConfig = (home as NSString).appendingPathComponent(".config/opencode")

        checkFile(
            fm: fm, root: projectRoot, rel: "opencode.json", name: "opencode.json", icon: "gearshape",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".opencode/AGENTS.md", name: "AGENTS.md", icon: "doc.text",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: xdgConfig, rel: "opencode.json", name: "Global Config", icon: "gearshape",
            scope: "global", into: &config)
        checkFile(
            fm: fm, root: xdgConfig, rel: "AGENTS.md", name: "Global AGENTS.md", icon: "doc.text",
            scope: "global", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "AGENTS.md", name: "AGENTS.md", icon: "person.2",
            scope: "project", into: &config)

        let skillsDir = (projectRoot as NSString).appendingPathComponent(".opencode/skills")
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
        let globalSkillsDir = (xdgConfig as NSString).appendingPathComponent("skills")
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

        scanOpenCodeMCP(fm: fm, root: projectRoot, configDir: xdgConfig, into: &config)

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

    nonisolated private static func scanOpenCodeMCP(
        fm: FileManager, root: String, configDir: String, into config: inout AgentConfig
    ) {
        for configPath in [
            (root as NSString).appendingPathComponent("opencode.json"),
            (configDir as NSString).appendingPathComponent("opencode.json")
        ] {
            guard let data = fm.contents(atPath: configPath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let mcp = json["mcp"] as? [String: Any]
            else { continue }

            for name in mcp.keys.sorted() {
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
