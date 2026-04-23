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
    private(set) var currentCwd: String?
    private(set) var diffStats: [DiffStatEntry] = []
    private(set) var worktrees: [ClaudeWorktree] = []
    private(set) var agentConfig: AgentConfig = AgentConfig()
    /// Session ID currently being written to (detected via file watching)
    private(set) var activeSessionID: String?

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var lastWorktreeScanRoot: String?
    private var refreshTimer: DispatchSourceTimer?
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
                            self?.startAgent(kind: session.agent.kind, cwd: session.agent.cwd)
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
                generation: UInt64(openSessions.count)
                    &+ UInt64(bitPattern: Int64(openSessions.map(\.id.hashValue).reduce(0, &+))))
            sections.append(openSessionsSection)
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
                generation: UInt64(worktrees.count))
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
                generation: UInt64(agentConfig.configFiles.count))
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
                generation: UInt64(agentConfig.skills.count))
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
                generation: UInt64(installedAgents.count))
            sections.append(emptySection)
        }

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: sections)
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }

    private func startAgent(kind: AgentKind, cwd: String? = nil) {
        let cwd = cwd ?? currentCwd ?? activeAgent?.cwd ?? "~"
        let command: String
        switch kind {
        case .claudeCode:
            command = "claude"
        case .codex:
            command = "codex"
        case .openCode:
            command = "opencode"
        case .custom:
            return
        }
        actions?.openTab?(.terminalWithCommand(workingDirectory: cwd, command: command))
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let active = Self.agentSession(from: context, existingStart: agentStartTime)
        if let active {
            cancelTeardown()
            if agentStartTime == nil {
                agentStartTime = active.startedAt
                currentCwd = context.cwd
                onRequestCycleRerun?()
                scanAgentConfig(cwd: context.cwd)
                scanWorktrees(cwd: context.cwd)
            }
            activeAgent = active
            if let sessionID = active.sessionID, activeSessionID != sessionID {
                activeSessionID = sessionID
                actions?.setAgentSessionID?(sessionID)
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
        let active = Self.agentSession(from: context, existingStart: agentStartTime)
        if let active {
            cancelTeardown()
            if agentStartTime == nil {
                agentStartTime = active.startedAt
                activeAgent = active
                currentCwd = context.cwd
                scanAgentConfig(cwd: context.cwd)
                scanWorktrees(cwd: context.cwd)
            }
            activeAgent = active
            refreshDiffStats(repoRoot: context.gitContext?.repoRoot)
            startRefreshTimer(repoRoot: context.gitContext?.repoRoot)
        } else {
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
            debugLog("[Agents] Failed to enumerate worktrees directory: \(error)")
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

        scanCodexConfig(fm: fm, root: projectRoot, home: home, into: &config)
        scanOpenCodeConfig(fm: fm, root: projectRoot, home: home, into: &config)
        populateAgentSetup(projectRoot: projectRoot, config: &config)

        return config
    }

    nonisolated private static func checkFile(
        fm: FileManager, root: String, rel: String, name: String,
        icon: String, scope: String, into config: inout AgentConfig
    ) {
        checkFile(
            fm: fm, root: root, rel: rel, name: name, icon: icon, scope: scope, provider: .claudeCode, into: &config)
    }

    nonisolated private static func checkFile(
        fm: FileManager, root: String, rel: String, name: String,
        icon: String, scope: String, provider: AgentKind, into config: inout AgentConfig
    ) {
        let fullPath = (root as NSString).appendingPathComponent(rel)
        if fm.fileExists(atPath: fullPath) {
            if !config.configFiles.contains(where: { $0.path == fullPath }) {
                config.configFiles.append(
                    AgentConfig.ConfigFile(name: name, path: fullPath, icon: icon, scope: scope, provider: provider))
            }
        }
    }

    nonisolated private static func scanCodexConfig(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        checkFile(
            fm: fm, root: root, rel: ".codex/config.toml", name: "Codex Config", icon: "gearshape",
            scope: "project", provider: .codex, into: &config)
        checkFile(
            fm: fm, root: home, rel: ".codex/config.toml", name: "Global Codex Config", icon: "gearshape",
            scope: "global", provider: .codex, into: &config)
    }

    nonisolated private static func scanOpenCodeConfig(
        fm: FileManager, root: String, home: String, into config: inout AgentConfig
    ) {
        checkFile(
            fm: fm, root: root, rel: "opencode.json", name: "OpenCode Config", icon: "gearshape",
            scope: "project", provider: .openCode, into: &config)
        checkFile(
            fm: fm, root: root, rel: "opencode.jsonc", name: "OpenCode Config", icon: "gearshape",
            scope: "project", provider: .openCode, into: &config)
        checkFile(
            fm: fm, root: root, rel: ".opencode", name: "OpenCode Plugins", icon: "puzzlepiece.extension",
            scope: "project", provider: .openCode, into: &config)
        checkFile(
            fm: fm, root: home, rel: ".config/opencode/opencode.json", name: "Global OpenCode Config",
            icon: "gearshape", scope: "global", provider: .openCode, into: &config)

        for path in [
            (root as NSString).appendingPathComponent("opencode.json"),
            (root as NSString).appendingPathComponent("opencode.jsonc"),
            (home as NSString).appendingPathComponent(".config/opencode/opencode.json")
        ] {
            guard let data = fm.contents(atPath: path),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let agent = json["agent"] as? [String: Any] {
                for name in agent.keys.sorted() {
                    config.skills.append(
                        AgentConfig.SkillEntry(
                            name: "@\(name)", description: "OpenCode agent", path: path, provider: .openCode))
                }
            }
        }
    }

    nonisolated private static func populateAgentSetup(projectRoot: String, config: inout AgentConfig) {
        let claudeConfigCount = config.configFiles.filter { $0.provider == .claudeCode }.count
        let codexConfigCount = config.configFiles.filter { $0.provider == .codex }.count
        let openCodeConfigCount = config.configFiles.filter { $0.provider == .openCode }.count

        config.toolSummaries = [
            AgentToolSummary(
                kind: .claudeCode,
                status: claudeConfigCount > 0 ? .detected : .missing,
                configCount: claudeConfigCount,
                detail: claudeConfigCount > 0 ? "Claude project or user config found" : "No Claude Code config found"),
            AgentToolSummary(
                kind: .codex,
                status: codexConfigCount > 0 ? .detected : .missing,
                configCount: codexConfigCount,
                detail: codexConfigCount > 0 ? "Codex config visible" : "No Codex config found"),
            AgentToolSummary(
                kind: .openCode,
                status: openCodeConfigCount > 0 ? .detected : .missing,
                configCount: openCodeConfigCount,
                detail: openCodeConfigCount > 0 ? "OpenCode config/plugins visible" : "No OpenCode config found")
        ]

        config.setupRecommendations = [
            AgentSetupRecommendation(
                kind: .claudeCode,
                status: claudeConfigCount > 0 ? .detected : .missing,
                title: "Claude Code",
                detail: claudeConfigCount > 0
                    ? "Boo detects Claude by process."
                    : "No Claude Code config found.",
                primaryAction: claudeConfigCount > 0 ? "Open config" : nil),
            AgentSetupRecommendation(
                kind: .codex,
                status: codexConfigCount > 0 ? .detected : .missing,
                title: "Codex",
                detail: codexConfigCount > 0
                    ? "Boo detects Codex by process."
                    : "No Codex config found.",
                primaryAction: codexConfigCount > 0 ? "Open config" : nil),
            AgentSetupRecommendation(
                kind: .openCode,
                status: openCodeConfigCount > 0 ? .detected : .missing,
                title: "OpenCode",
                detail: openCodeConfigCount > 0
                    ? "Boo detects OpenCode by process."
                    : "No OpenCode config found.",
                primaryAction: openCodeConfigCount > 0 ? "Open config" : nil)
        ]
    }

    private func handleSetupAction(_ recommendation: AgentSetupRecommendation) {
        switch recommendation.kind {
        case .claudeCode:
            openFirstConfig(for: .claudeCode)
        case .codex:
            openFirstConfig(for: .codex)
        case .openCode:
            openFirstConfig(for: .openCode)
        case .custom:
            break
        }
    }

    private func openFirstConfig(for kind: AgentKind) {
        guard let path = agentConfig.configFiles.first(where: { $0.provider == kind })?.path else { return }
        actions?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentsConstants.diffDebounceDelay, execute: work)
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
    task.launchPath = "/usr/bin/git"
    task.arguments = ["-C", repoRoot, "diff", "--numstat", "HEAD"]
    task.standardError = FileHandle.nullDevice

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
    } catch {
        debugLog("[Agents] git diff task failed: \(error)")
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
        return AgentsPlugin.DiffStatEntry(
            path: filePath,
            insertions: insertions,
            deletions: deletions,
            fullPath: fullPath
        )
    }
}
