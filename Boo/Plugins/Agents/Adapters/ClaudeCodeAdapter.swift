import Foundation

struct ClaudeCodeAdapter: AgentAdapter {
    let kind = AgentKind.claudeCode
    let displayName = "Claude Code"
    let shortName = "Claude"
    let binary = "claude"
    var aliases: Set<String> { ["claude", "claude-code", "claudecode"] }
    var titleKeywords: [String] { ["claude"] }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return binary + modelFlag(model)
        case .continueLast: return "claude --continue"
        case .resume(let id): return "claude --resume " + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project(".claude/CLAUDE.md", "CLAUDE.md", icon: "doc.text"),
            .project("CLAUDE.md", "CLAUDE.md", icon: "doc.text"),
            .project(".claude/settings.json", "Settings"),
            .project(".claude/settings.local.json", "Local Settings"),
            .project(".claude/mcp.json", "MCP Servers", icon: "server.rack"),
            .global(".claude/settings.json", "Global Settings"),
            .global(".claude.json", "Global MCP", icon: "server.rack"),
            .global(".claude/CLAUDE.md", "Global CLAUDE.md", icon: "doc.text"),
            .project("AGENTS.md", "AGENTS.md", icon: "person.2")
        ]
    }

    /// Skills in `.claude/skills/<name>/SKILL.md`; a project skill hides the global one of that name.
    func scanExtraConfig(root: String, home: String, into config: inout AgentsPlugin.AgentConfig) {
        let fm = FileManager.default
        for base in [root, home] {
            let dir = (base as NSString).appendingPathComponent(".claude/skills")
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let known = Set(config.skills.filter { $0.provider == kind }.map(\.name))
            for entry in entries.sorted() where !known.contains(entry) {
                let skillMd = (dir as NSString).appendingPathComponent("\(entry)/SKILL.md")
                guard fm.fileExists(atPath: skillMd) else { continue }
                config.skills.append(
                    AgentsPlugin.AgentConfig.SkillEntry(
                        name: entry, description: parseAgentSkillDescription(at: skillMd), path: skillMd))
            }
        }
    }

    func installIntegration() { BooPaths.installClaudeHook() }
}
