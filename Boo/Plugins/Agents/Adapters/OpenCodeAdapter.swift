import Foundation

struct OpenCodeAdapter: AgentAdapter {
    let kind = AgentKind.openCode
    let displayName = "OpenCode"
    let shortName = "OpenCode"
    let binary = "opencode"
    var aliases: Set<String> { ["opencode", "open-code", "open_code"] }
    var titleKeywords: [String] { ["opencode", "open code"] }
    var promptStyle: AgentPromptStyle { .flag("--prompt") }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return binary + modelFlag(model)
        case .continueLast: return "opencode --continue"
        case .resume(let id): return "opencode --session " + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project("opencode.json", "OpenCode Config"),
            .project("opencode.jsonc", "OpenCode Config"),
            .project(".opencode", "OpenCode Plugins", icon: "puzzlepiece.extension"),
            .global(".config/opencode/opencode.json", "Global OpenCode Config")
        ]
    }

    /// Named agents from the `agent` table of opencode.json.
    func scanExtraConfig(root: String, home: String, into config: inout AgentsPlugin.AgentConfig) {
        for path in [
            (root as NSString).appendingPathComponent("opencode.json"),
            (root as NSString).appendingPathComponent("opencode.jsonc"),
            (home as NSString).appendingPathComponent(".config/opencode/opencode.json")
        ] {
            guard let data = FileManager.default.contents(atPath: path),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let agent = json["agent"] as? [String: Any]
            else { continue }
            for name in agent.keys.sorted() {
                config.skills.append(
                    AgentsPlugin.AgentConfig.SkillEntry(
                        name: "@\(name)", description: "OpenCode agent", path: path, provider: kind))
            }
        }
    }

    func installIntegration() { BooPaths.installOpenCodePlugin() }
}
