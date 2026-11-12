import Foundation

/// pi (`pi`, from @earendil-works/pi-coding-agent). Runs under node.
struct PiAdapter: AgentAdapter {
    let kind = AgentKind.pi
    let displayName = "pi"
    let shortName = "pi"
    let binary = "pi"
    var argvPatterns: [String] { ["pi-coding-agent"] }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return binary + modelFlag(model)
        case .continueLast: return "pi --continue"
        case .resume(let id): return "pi --session " + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project(".pi/settings.json", "pi Settings"),
            .project(".pi/extensions", "pi Extensions", icon: "puzzlepiece.extension"),
            .global(".pi/agent/settings.json", "Global pi Settings"),
            .global(".pi/agent/AGENTS.md", "Global pi AGENTS.md", icon: "doc.text")
        ]
    }

    /// Boo's extension in ~/.pi/agent/extensions/boo.ts. Skipped while pi was never set up.
    func installIntegration() {
        let root = NSHomeDirectory().appendingPathComponent(".pi/agent")
        guard FileManager.default.fileExists(atPath: root),
            let data = AgentIntegrationFiles.bundled("boo-pi-extension.ts")
        else { return }
        AgentIntegrationFiles.write(data, to: root.appendingPathComponent("extensions/boo.ts"))
    }
}
