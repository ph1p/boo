import Foundation

struct CodexAdapter: AgentAdapter {
    let kind = AgentKind.codex
    let displayName = "Codex"
    let shortName = "Codex"
    let binary = "codex"
    var titleKeywords: [String] { ["codex"] }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return binary + modelFlag(model)
        case .continueLast: return "codex resume --last"
        case .resume(let id): return "codex resume " + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project(".codex/config.toml", "Codex Config"),
            .global(".codex/config.toml", "Global Codex Config")
        ]
    }

    func installIntegration() { BooPaths.installCodexNotify() }
}
