import Foundation

/// Hermes Agent (`hermes`, Nous Research). Runs under python.
struct HermesAdapter: AgentAdapter {
    let kind = AgentKind.hermes
    let displayName = "Hermes"
    let shortName = "Hermes"
    let binary = "hermes"
    /// python runs `.../bin/hermes` or `-m hermes_cli`; a bare "hermes" would match
    /// every python in Hermes' own venv (~/.hermes/...).
    var argvPatterns: [String] { ["bin/hermes", "hermes_cli"] }
    var titleKeywords: [String] { ["hermes"] }
    /// `hermes chat -q` answers once and exits: Boo's plugin types the prompt instead.
    var promptStyle: AgentPromptStyle { .firstPromptEnv }

    func baseCommand(_ invocation: AgentInvocation) -> String {
        switch invocation {
        case .start(let model): return "hermes chat" + modelFlag(model)
        case .continueLast: return "hermes chat --continue"
        case .resume(let id): return "hermes chat --resume " + shellEscape(id)
        }
    }

    var configFiles: [AgentConfigFileSpec] {
        [
            .project(".hermes.md", ".hermes.md", icon: "doc.text"),
            .project("HERMES.md", "HERMES.md", icon: "doc.text"),
            .global(".hermes/config.yaml", "Global Hermes Config"),
            .global(".hermes/SOUL.md", "Hermes SOUL.md", icon: "doc.text")
        ]
    }

    static let pluginManifest = """
        name: boo
        version: 1.0.0
        description: Reports Hermes' state to Boo's agent inbox and types Boo's first prompt.
        """

    /// Boo's plugin in ~/.hermes/plugins/boo/. Skipped while Hermes was never set up.
    func installIntegration() {
        let root = NSHomeDirectory().appendingPathComponent(".hermes")
        guard FileManager.default.fileExists(atPath: root),
            let plugin = AgentIntegrationFiles.bundled("boo-hermes-plugin.py")
        else { return }
        let dir = root.appendingPathComponent("plugins/boo")
        AgentIntegrationFiles.write(Data((Self.pluginManifest + "\n").utf8), to: dir + "/plugin.yaml")
        AgentIntegrationFiles.write(plugin, to: dir + "/__init__.py")
    }
}
