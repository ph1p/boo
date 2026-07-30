import AppKit
import Foundation

// MARK: - Agent Config Scan

extension AgentsPlugin {
    func scanAgentConfig(cwd: String?) {
        guard let cwd = cwd else { return }

        withProjectRoot(cwd: cwd) { [weak self] projectRoot in
            guard let self else { return }
            // Record the cwd before the TTL early-return: `makeSidebarTab` gates its
            // scan dispatch on `currentCwd != context.terminal.cwd`, so leaving it
            // unset would re-dispatch both scans on every call for the whole TTL window.
            self.currentCwd = cwd
            // Root equality alone made this permanently sticky — a CLAUDE.md or skill
            // added to the same project never showed up. Re-scan once the TTL expires.
            guard self.configScan.shouldScan(root: projectRoot, ttl: Self.scanTTL) else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                let config = Self.detectAgentConfig(cwd: cwd, projectRoot: projectRoot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // A TTL re-scan that finds nothing new must not trigger a sidebar
                    // rebuild — that would restart the rebuild/focus churn the debounce
                    // exists to prevent.
                    let unchanged =
                        self.agentConfig.configFiles.map(\.path) == config.configFiles.map(\.path)
                        && self.agentConfig.skills.map(\.path) == config.skills.map(\.path)
                    self.agentConfig = config
                    if !unchanged { self.onRequestCycleRerun?() }
                }
            }
        }
    }

    /// Pass `projectRoot` when the caller already resolved it — `findAgentProjectRoot`
    /// walks up to 20 levels x 4 markers of `fileExists`, and the scan path has it.
    nonisolated static func detectAgentConfig(cwd: String, projectRoot: String? = nil) -> AgentConfig {
        let fm = FileManager.default
        var config = AgentConfig()
        let home = fm.homeDirectoryForCurrentUser.path
        let projectRoot = projectRoot ?? findAgentProjectRoot(from: cwd, markers: projectMarkers) ?? cwd

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

}
