import Foundation

/// GitHub Copilot CLI (`copilot`, from @github/copilot).
struct CopilotAdapter: AgentAdapter {
    let kind = AgentKind.copilot
    let displayName = "GitHub Copilot"
    let shortName = "Copilot"
    let binary = "copilot"
    var aliases: Set<String> { ["copilot", "github-copilot", "copilot-cli", "github"] }
    /// The npm package path: node runs `@github/copilot/index.js`.
    var argvPatterns: [String] { ["@github/copilot"] }
    var titleKeywords: [String] { ["copilot"] }
    /// `-p` would run one prompt and exit; `-i` keeps the session open.
    var promptStyle: AgentPromptStyle { .flag("-i") }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return binary + modelFlag(model)
        case .continueLast: return "copilot --continue"
        case .resume(let id): return "copilot --resume=" + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project(".github/copilot-instructions.md", "Copilot Instructions", icon: "doc.text"),
            .project(".github/copilot/settings.json", "Copilot Settings"),
            .project(".github/hooks", "Copilot Hooks", icon: "puzzlepiece.extension"),
            .global(".copilot/settings.json", "Global Copilot Settings"),
            .global(".copilot/mcp-config.json", "Copilot MCP", icon: "server.rack"),
            .global(".copilot/copilot-instructions.md", "Global Copilot Instructions", icon: "doc.text")
        ]
    }

    /// The events boo-claude-hook handles for Copilot.
    static let hookEvents = [
        "sessionStart", "userPromptSubmitted", "preToolUse", "notification", "agentStop", "sessionEnd"
    ]

    /// Copilot's home: `$COPILOT_HOME`, else ~/.copilot.
    static var home: String {
        if let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"], !custom.isEmpty { return custom }
        return NSHomeDirectory().appendingPathComponent(".copilot")
    }

    /// ~/.copilot/hooks/boo.json: runs boo-claude-hook for each event.
    /// Skipped while Copilot was never set up.
    func installIntegration() {
        guard FileManager.default.fileExists(atPath: Self.home),
            let data = Self.hooksJSON(hook: BooPaths.agentHookPath)
        else { return }
        AgentIntegrationFiles.write(data, to: Self.home.appendingPathComponent("hooks/boo.json"))
    }

    /// Copilot's hooks file that calls `hook copilot <event>` for each event.
    static func hooksJSON(hook: String) -> Data? {
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            hooks[event] = [["type": "command", "bash": shellEscape(hook) + " copilot " + event, "timeoutSec": 5]]
        }
        return try? JSONSerialization.data(
            withJSONObject: ["version": 1, "hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    }
}
