import SwiftUI

/// Built-in plugin that monitors running AI coding agents (Claude, Codex, etc.).
/// Shows agent name, runtime, configuration files, hooks, skills, and changed files.
/// Appears automatically when an AI agent is the foreground process.
@MainActor
final class AIAgentPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "ai-agent",
        name: "AI Agent",
        version: "1.0.0",
        icon: "sparkles",
        description: "Monitor running AI coding agents",
        when: "process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 20, template: nil),
        settings: nil
    )

    var prefersOuterScrollView: Bool { false }

    /// Override default visibility: remain visible while agent state is still set
    /// (during deferred teardown or while subprocesses run).
    func isVisible(for context: TerminalContext) -> Bool {
        if !AppSettings.shared.isPluginEnabled(pluginID) { return false }
        // Still visible while we have agent state (deferred teardown pending)
        if agentName != nil { return true }
        guard let clause = whenClause else { return true }
        return WhenClauseEvaluator.evaluate(clause, context: context)
    }

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .cwdChanged, .focusChanged] }

    // MARK: - Cached State

    private(set) var agentName: String?
    private(set) var agentDisplayName: String?
    private(set) var agentIcon: String?
    private(set) var agentStartTime: Date?
    private(set) var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []

    /// Detected agent configuration for the current project.
    private(set) var agentConfig: AgentConfig = AgentConfig()

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var refreshTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?

    /// Monotonic counter to identify the active deferred teardown.
    private var teardownGeneration: UInt64 = 0

    /// Grace period before tearing down when the process switches away from AI.
    private let teardownGracePeriod: TimeInterval = 2.0

    struct DiffStatEntry: Identifiable {
        let id = UUID()
        let path: String
        let insertions: Int
        let deletions: Int
        let fullPath: String
    }

    /// Aggregated agent configuration detected from the file system.
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
            let scope: String  // "project" or "global"
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
        guard let name = agentName else { return }
        context.setData(AnyHashable(name), forKey: "ai-agent.name")
        if let start = agentStartTime {
            let runtime = Int(Date().timeIntervalSince(start))
            context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
        }
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let displayName = agentDisplayName else { return nil }
        var text = displayName
        if !diffStats.isEmpty {
            let count = diffStats.count
            text += " \u{00B7} \(count) file\(count == 1 ? "" : "s")"
        }
        if let start = agentStartTime {
            let mins = Int(Date().timeIntervalSince(start) / 60)
            if mins > 0 {
                text += " \u{00B7} \(formatRuntime(Date().timeIntervalSince(start)))"
            }
        }
        return StatusBarContent(
            text: text,
            icon: "sparkles",
            tint: .accent,
            accessibilityLabel: "AI Agent: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard let displayName = agentDisplayName else { return nil }
        if let start = agentStartTime {
            let runtime = Date().timeIntervalSince(start)
            return "\(displayName) \u{00B7} \(formatRuntime(runtime))"
        }
        return displayName
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard agentDisplayName != nil else { return nil }
        let act = actions
        let fontSize: CGFloat = 11.0

        return AnyView(
            AIAgentDetailView(
                diffStats: diffStats,
                agentConfig: agentConfig,
                fontSize: fontSize,
                textColor: Color(nsColor: context.theme.chromeText),
                mutedColor: Color(nsColor: context.theme.chromeMuted),
                accentColor: context.theme.ansiColors.count > 13
                    ? Color(nsColor: context.theme.ansiColors[13])
                    : Color(nsColor: context.theme.accentColor),
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

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let isAI = ProcessIcon.category(for: name) == "ai"
        if isAI {
            cancelTeardown()

            if agentName != name {
                agentName = name
                agentDisplayName = ProcessIcon.displayName(for: name) ?? name
                agentIcon = ProcessIcon.icon(for: name)
                agentStartTime = Date()
                currentCwd = context.cwd
                scanAgentConfig(cwd: context.cwd, agentName: name)
            }
            refreshDiffStats(repoRoot: context.gitContext?.repoRoot)
            startRefreshTimer(repoRoot: context.gitContext?.repoRoot)
        } else if agentName != nil {
            // Process switched away from AI — always defer teardown.
            // Never tear down immediately: the AI agent may have spawned a
            // subprocess, or the title may be flickering during a transition.
            scheduleDeferredTeardown()
        }
    }

    private func cancelTeardown() {
        teardownGeneration &+= 1
    }

    /// Schedule a deferred teardown. Invalidates any previous schedule.
    private func scheduleDeferredTeardown() {
        teardownGeneration &+= 1
        let gen = teardownGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownGracePeriod) { [weak self] in
            guard let self = self, self.teardownGeneration == gen else { return }
            self.performTeardown()
        }
    }

    func cwdChanged(newPath: String, context: TerminalContext) {
        // CWD is locked to the directory where the agent was launched.
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        let isAI = ProcessIcon.category(for: context.processName) == "ai"
        if isAI {
            cancelTeardown()
            if agentName != context.processName {
                agentName = context.processName
                agentDisplayName = ProcessIcon.displayName(for: context.processName) ?? context.processName
                agentIcon = ProcessIcon.icon(for: context.processName)
                agentStartTime = Date()
                currentCwd = context.cwd
                scanAgentConfig(cwd: context.cwd, agentName: context.processName)
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
        agentName = nil
        agentDisplayName = nil
        agentIcon = nil
        agentStartTime = nil
        diffStats = []
        agentConfig = AgentConfig()
        lastDiffRepoRoot = nil
        lastConfigScanRoot = nil
        stopRefreshTimer()
    }

    // MARK: - Agent Config Scan

    private func scanAgentConfig(cwd: String?, agentName: String?) {
        guard let cwd = cwd, let agent = agentName else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Find project root first — cache based on root, not CWD
            let projectRoot = Self.findProjectRoot(from: cwd) ?? cwd
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentName != nil else { return }
                if self.lastConfigScanRoot == projectRoot { return }
                self.lastConfigScanRoot = projectRoot

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let config = Self.detectAgentConfig(cwd: cwd, agentName: agent)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.agentName != nil else { return }
                        self.agentConfig = config
                        self.onRequestCycleRerun?()
                    }
                }
            }
        }
    }

    nonisolated static func detectAgentConfig(cwd: String, agentName: String) -> AgentConfig {
        let fm = FileManager.default
        var config = AgentConfig()
        let home = fm.homeDirectoryForCurrentUser.path

        // Find project root (walk up to find .git or known config markers)
        let projectRoot = findProjectRoot(from: cwd) ?? cwd

        // --- Config files ---

        // Agent-specific configs
        let agentKey = agentName.lowercased()

        // Claude Code
        if agentKey == "claude" {
            checkFile(
                fm: fm, root: projectRoot, rel: ".claude/CLAUDE.md", name: "CLAUDE.md", icon: "doc.text",
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

            // Scan skills
            let skillsDir = (projectRoot as NSString).appendingPathComponent(".claude/skills")
            if let entries = try? fm.contentsOfDirectory(atPath: skillsDir) {
                for entry in entries.sorted() {
                    let skillMd = (skillsDir as NSString).appendingPathComponent("\(entry)/SKILL.md")
                    if fm.fileExists(atPath: skillMd) {
                        let desc = parseSkillDescription(at: skillMd)
                        config.skills.append(
                            AgentConfig.SkillEntry(
                                name: entry,
                                description: desc,
                                path: skillMd
                            ))
                    }
                }
            }
            // Global skills
            let globalSkillsDir = (home as NSString).appendingPathComponent(".claude/skills")
            if let entries = try? fm.contentsOfDirectory(atPath: globalSkillsDir) {
                let projectSkillNames = Set(config.skills.map(\.name))
                for entry in entries.sorted() {
                    guard !projectSkillNames.contains(entry) else { continue }
                    let skillMd = (globalSkillsDir as NSString).appendingPathComponent("\(entry)/SKILL.md")
                    if fm.fileExists(atPath: skillMd) {
                        let desc = parseSkillDescription(at: skillMd)
                        config.skills.append(
                            AgentConfig.SkillEntry(
                                name: entry,
                                description: desc,
                                path: skillMd
                            ))
                    }
                }
            }

            // Scan hooks from settings
            scanClaudeHooks(fm: fm, root: projectRoot, home: home, into: &config)

            // Scan MCP servers
            scanClaudeMCP(fm: fm, root: projectRoot, home: home, into: &config)
        }

        // Codex
        if agentKey == "codex" {
            checkFile(
                fm: fm, root: projectRoot, rel: "codex.md", name: "codex.md", icon: "doc.text", scope: "project",
                into: &config)
            checkFile(
                fm: fm, root: projectRoot, rel: ".codex/config.toml", name: "Config", icon: "gearshape",
                scope: "project", into: &config)
            checkFile(
                fm: fm, root: home, rel: ".codex/config.toml", name: "Global Config", icon: "gearshape",
                scope: "global", into: &config)
        }

        // Aider
        if agentKey == "aider" {
            checkFile(
                fm: fm, root: projectRoot, rel: ".aider.conf.yml", name: ".aider.conf.yml", icon: "gearshape",
                scope: "project", into: &config)
            checkFile(
                fm: fm, root: projectRoot, rel: ".aiderignore", name: ".aiderignore", icon: "eye.slash",
                scope: "project", into: &config)
            checkFile(
                fm: fm, root: home, rel: ".aider.conf.yml", name: "Global Config", icon: "gearshape", scope: "global",
                into: &config)
        }

        // Cursor
        if agentKey == "cursor" || agentKey == "cursor-cli" {
            checkFile(
                fm: fm, root: projectRoot, rel: ".cursorrules", name: ".cursorrules", icon: "doc.text",
                scope: "project", into: &config)
            checkFile(
                fm: fm, root: projectRoot, rel: ".cursor/mcp.json", name: "MCP Servers", icon: "server.rack",
                scope: "project", into: &config)
            // Scan .cursor/rules/*.mdc
            let rulesDir = (projectRoot as NSString).appendingPathComponent(".cursor/rules")
            if let entries = try? fm.contentsOfDirectory(atPath: rulesDir) {
                for entry in entries.sorted() where entry.hasSuffix(".mdc") {
                    let ruleName = (entry as NSString).deletingPathExtension
                    let rulePath = (rulesDir as NSString).appendingPathComponent(entry)
                    config.configFiles.append(
                        AgentConfig.ConfigFile(
                            name: ruleName,
                            path: rulePath,
                            icon: "list.bullet.rectangle",
                            scope: "project"
                        ))
                }
            }
        }

        // Copilot
        if agentKey == "copilot" {
            checkFile(
                fm: fm, root: projectRoot, rel: ".github/copilot-instructions.md", name: "Copilot Instructions",
                icon: "doc.text", scope: "project", into: &config)
            checkFile(
                fm: fm, root: projectRoot, rel: ".vscode/mcp.json", name: "MCP Servers", icon: "server.rack",
                scope: "project", into: &config)
        }

        // Generic config files (all agents)
        checkFile(
            fm: fm, root: projectRoot, rel: "AGENTS.md", name: "AGENTS.md", icon: "person.2", scope: "project",
            into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".rules", name: ".rules", icon: "list.bullet.rectangle", scope: "project",
            into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "CONVENTIONS.md", name: "CONVENTIONS.md", icon: "doc.text",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "CONTRIBUTING.md", name: "CONTRIBUTING.md", icon: "doc.text",
            scope: "project", into: &config)

        return config
    }

    // MARK: - Config Scan Helpers

    nonisolated private static func findProjectRoot(from path: String) -> String? {
        let fm = FileManager.default
        var dir = path
        let markers = [".git", ".claude", ".cursor", ".codex", ".aider.conf.yml", "AGENTS.md"]
        for _ in 0..<20 {
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

    nonisolated private static func checkFile(
        fm: FileManager, root: String, rel: String, name: String,
        icon: String, scope: String, into config: inout AgentConfig
    ) {
        let fullPath = (root as NSString).appendingPathComponent(rel)
        if fm.fileExists(atPath: fullPath) {
            config.configFiles.append(
                AgentConfig.ConfigFile(
                    name: name, path: fullPath, icon: icon, scope: scope
                ))
        }
    }

    nonisolated private static func parseSkillDescription(at path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path),
            let content = String(data: data, encoding: .utf8)
        else { return "" }

        // Parse YAML frontmatter for description
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

    nonisolated private static func scanClaudeHooks(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        // Check project settings first, then global
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
                                config.hooks.append(
                                    AgentConfig.HookEntry(
                                        event: event, command: shortCmd
                                    ))
                            }
                        }
                    }
                }
            }
            break  // Use the first settings file that has hooks
        }
    }

    nonisolated private static func scanClaudeMCP(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        // Check project mcp.json, then global
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

    // MARK: - Git Diff Stats (Background)

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
            guard let self = self else { return }
            self.runDiffDetection(repoRoot: root)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func runDiffDetection(repoRoot: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = Self.detectDiffStats(repoRoot: repoRoot)
            DispatchQueue.main.async {
                guard let self = self, self.agentName != nil else { return }
                // Only trigger a sidebar rebuild when files are added/removed,
                // not when line counts change — avoids file tree jumping.
                let oldPaths = self.diffStats.map(\.path)
                let newPaths = stats.map(\.path)
                self.diffStats = stats
                if oldPaths != newPaths {
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    nonisolated static func detectDiffStats(repoRoot: String) -> [DiffStatEntry] {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "diff", "--numstat", "HEAD"]
        task.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
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
            return DiffStatEntry(
                path: filePath,
                insertions: insertions,
                deletions: deletions,
                fullPath: fullPath
            )
        }
    }

    // MARK: - Periodic Refresh Timer

    private func startRefreshTimer(repoRoot: String?) {
        stopRefreshTimer()
        guard let root = repoRoot else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.agentName != nil else {
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

// MARK: - Formatting

private func formatRuntime(_ seconds: TimeInterval) -> String {
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
