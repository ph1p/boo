import SwiftUI

/// Built-in plugin for Codex AI assistant.
/// Shows sessions, config files, and changed files.
/// Appears when Codex is the foreground process.
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
        icon: "sparkles",
        description: "Codex AI assistant",
        when: "process.codex",
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

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard agentStartTime != nil else { return nil }
        let act = actions
        let fontScale = context.fontScale
        let cwd = currentCwd

        return AnyView(
            CodexDetailView(
                sessions: sessions,
                diffStats: diffStats,
                agentConfig: agentConfig,
                fontScale: fontScale,
                textColor: Color(nsColor: context.theme.chromeText),
                mutedColor: Color(nsColor: context.theme.chromeMuted),
                accentColor: context.theme.ansiColors.count > 13
                    ? Color(nsColor: context.theme.ansiColors[13])
                    : Color(nsColor: context.theme.accentColor),
                currentCwd: cwd,
                onSessionClicked: { [weak self] session in
                    self?.resumeSession(session)
                },
                onFileClicked: { path in
                    act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                },
                onCopyPath: { path in
                    act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                }
            )
        )
    }

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

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = Self.detectSessions(forCwd: cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentStartTime != nil else { return }
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
