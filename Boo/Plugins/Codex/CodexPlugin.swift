import SwiftUI

/// Built-in plugin for Codex AI assistant.
/// Shows sessions, config files, and changed files.
/// Always visible when enabled; shows active agent status when running.
@MainActor
final class CodexPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "codex",
        name: "Codex",
        version: "1.0.0",
        icon: "asset:codex-icon",
        description: "Codex AI assistant",
        when: nil,  // Always visible
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
    private(set) var sessions: [CodexSession] = []
    private(set) var agentConfig: AgentConfig = AgentConfig()

    private var lastDiffRepoRoot: String?
    private var lastConfigScanRoot: String?
    private var lastSessionScanCwd: String?
    private var refreshTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var teardownGeneration: UInt64 = 0
    var teardownGracePeriod: TimeInterval = 2.0

    typealias DiffStatEntry = AgentDiffStatEntry

    static let projectMarkers = [".git", ".codex", "codex.md", "AGENTS.md"]

    struct CodexSession: Identifiable {
        let id: String
        let timestamp: Date
        let cwd: String
        let model: String?
        let path: String
    }

    struct AgentConfig {
        var configFiles: [ConfigFile] = []

        struct ConfigFile: Identifiable {
            let id = UUID()
            let name: String
            let path: String
            let icon: String
            let scope: String
        }
    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        guard agentStartTime != nil else { return }
        context.setData(AnyHashable("codex"), forKey: "ai-agent.name")
        if let start = agentStartTime {
            let runtime = Int(Date().timeIntervalSince(start))
            context.setData(AnyHashable(runtime), forKey: "ai-agent.runtime")
        }
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard agentStartTime != nil else { return nil }
        var text = "Codex"
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
            accessibilityLabel: "Codex: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard agentStartTime != nil else { return nil }
        if let start = agentStartTime {
            let runtime = Date().timeIntervalSince(start)
            return "Codex \u{00B7} \(formatAgentRuntime(runtime))"
        }
        return "Codex"
    }

    // MARK: - Sidebar Tab (multi-section)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }

        // If no agent running, scan config/sessions based on current terminal CWD
        let isAgentActive = agentStartTime != nil
        if !isAgentActive && currentCwd != context.terminal.cwd {
            scanAgentConfig(cwd: context.terminal.cwd)
            scanSessions(cwd: context.terminal.cwd)
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
            let statusSection = SidebarSection(
                id: "codex.status",
                name: "Active",
                icon: "bolt.fill",
                content: AnyView(
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Codex running")
                            .font(fontScale.font(.base))
                            .foregroundColor(textColor)
                        Spacer()
                        if let start = agentStartTime {
                            Text(formatAgentRuntime(Date().timeIntervalSince(start)))
                                .font(fontScale.font(.sm, design: .monospaced))
                                .foregroundColor(mutedColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                ),
                prefersOuterScrollView: false,
                generation: UInt64(agentStartTime?.timeIntervalSince1970 ?? 0)
            )
            sections.append(statusSection)
        }

        // Sessions section
        if !sessions.isEmpty {
            let sessionsSection = SidebarSection(
                id: "codex.sessions",
                name: "Sessions (\(sessions.count))",
                icon: "bubble.left.and.bubble.right",
                content: AnyView(
                    CodexSessionsView(
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

        // Config section
        if !agentConfig.configFiles.isEmpty {
            let configSection = SidebarSection(
                id: "codex.config",
                name: "Config (\(agentConfig.configFiles.count))",
                icon: "doc.text",
                content: AnyView(
                    CodexConfigView(
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
                        }
                    )),
                prefersOuterScrollView: true,
                generation: UInt64(agentConfig.configFiles.count))
            sections.append(configSection)
        }

        // Changes section
        if !diffStats.isEmpty {
            let ins = diffStats.reduce(0) { $0 + $1.insertions }
            let del = diffStats.reduce(0) { $0 + $1.deletions }
            let changesSection = SidebarSection(
                id: "codex.changes",
                name: "Changes (\(diffStats.count)) +\(ins) -\(del)",
                icon: "doc.badge.plus",
                content: AnyView(
                    CodexChangesView(
                        diffStats: diffStats,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        }
                    )),
                prefersOuterScrollView: true,
                generation: UInt64(diffStats.count))
            sections.append(changesSection)
        }

        // If no sections, show getting started
        if sections.isEmpty {
            let emptySection = SidebarSection(
                id: "codex",
                name: "Codex",
                icon: "brain",
                content: AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Codex sessions found")
                            .font(fontScale.font(.base))
                            .foregroundColor(textColor)
                        Text("Run `codex` in a terminal to start")
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

        // Badge shows active Codex agents
        let agentCount = AIAgentTracker.shared.agents(named: "codex").count

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: sections,
            badge: agentCount > 0 ? agentCount : nil)
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }

    // MARK: - Session Resume

    private func resumeSession(_ session: CodexSession) {
        actions?.sendToTerminal?("codex --resume \(session.id)\n")
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        let isCodex = name.lowercased() == "codex"
        if isCodex {
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
        let isCodex = context.processName.lowercased() == "codex"
        if isCodex {
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
        lastSessionScanCwd = nil
        stopRefreshTimer()
    }

    // MARK: - Session Scanning

    private func scanSessions(cwd: String?) {
        guard let cwd = cwd else { return }
        if lastSessionScanCwd == cwd { return }
        lastSessionScanCwd = cwd
        currentCwd = cwd

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = Self.detectSessions(forCwd: cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessions = sessions
                self.onRequestCycleRerun?()
            }
        }
    }

    nonisolated static func detectSessions(forCwd cwd: String) -> [CodexSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let sessionsDir = (home as NSString).appendingPathComponent(".codex/sessions")

        guard fm.fileExists(atPath: sessionsDir) else { return [] }

        var allSessions: [CodexSession] = []

        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        for year in years.sorted().reversed().prefix(2) {
            let yearDir = (sessionsDir as NSString).appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearDir) else { continue }

            for month in months.sorted().reversed() {
                let monthDir = (yearDir as NSString).appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthDir) else { continue }

                for day in days.sorted().reversed() {
                    let dayDir = (monthDir as NSString).appendingPathComponent(day)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayDir) else { continue }

                    for file in files where file.hasSuffix(".jsonl") {
                        let filePath = (dayDir as NSString).appendingPathComponent(file)
                        if let session = parseSessionFile(path: filePath, targetCwd: cwd) {
                            allSessions.append(session)
                        }
                    }
                }

                if allSessions.count >= 20 { break }
            }
            if allSessions.count >= 20 { break }
        }

        return
            allSessions
            .filter { $0.cwd == cwd }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(10)
            .map { $0 }
    }

    nonisolated private static func parseSessionFile(path: String, targetCwd: String) -> CodexSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.readToEnd(),
            let content = String(data: data, encoding: .utf8)
        else { return nil }

        guard let firstLine = content.components(separatedBy: "\n").first,
            let lineData = firstLine.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let type = json["type"] as? String, type == "session_meta",
            let payload = json["payload"] as? [String: Any],
            let sessionID = payload["id"] as? String,
            let sessionCwd = payload["cwd"] as? String
        else { return nil }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var timestamp: Date?
        if let ts = json["timestamp"] as? String {
            timestamp = dateFormatter.date(from: ts)
        } else if let ts = payload["timestamp"] as? String {
            timestamp = dateFormatter.date(from: ts)
        }

        guard let ts = timestamp else { return nil }

        let model = payload["model_provider"] as? String

        return CodexSession(
            id: sessionID,
            timestamp: ts,
            cwd: sessionCwd,
            model: model,
            path: path
        )
    }

    // MARK: - Agent Config Scan

    private func scanAgentConfig(cwd: String?) {
        guard let cwd = cwd else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let projectRoot = findAgentProjectRoot(from: cwd, markers: Self.projectMarkers) ?? cwd
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
        let projectRoot = findAgentProjectRoot(from: cwd, markers: Self.projectMarkers) ?? cwd

        checkFile(
            fm: fm, root: projectRoot, rel: "codex.md", name: "codex.md", icon: "doc.text",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: ".codex/config.toml", name: "Config", icon: "gearshape",
            scope: "project", into: &config)
        checkFile(
            fm: fm, root: home, rel: ".codex/config.toml", name: "Global Config", icon: "gearshape",
            scope: "global", into: &config)
        checkFile(
            fm: fm, root: projectRoot, rel: "AGENTS.md", name: "AGENTS.md", icon: "person.2",
            scope: "project", into: &config)

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
