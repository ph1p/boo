import Foundation

/// Wires Boo into the coding agents (each `AgentAdapter` installs its own
/// hook or plugin) while the agents switch is on. Off: nothing is installed or updated, and a flag file
/// makes the hooks already installed exit at once.
extension BooPaths {
    /// Present while agents are off; the agent hooks check it and stay quiet.
    static var agentsDisabledFlagPath: String {
        configDir.appendingPathComponent("agents-disabled")
    }

    /// The agents switch the last sync applied; nil before the first one.
    /// Read and written on the main thread only.
    nonisolated(unsafe) private static var syncedAgentsEnabled: Bool?

    /// Applies the agents switch: on installs or updates every agent's
    /// hook or plugin and the MCP/CLI launchers; off only writes the flag file.
    /// Cheap to call again: does nothing while the switch is unchanged.
    /// True when the switch changed since the last sync.
    @discardableResult
    static func syncAgentIntegration(enabled: Bool = AppSettings.shared.agentsEnabled) -> Bool {
        guard syncedAgentsEnabled != enabled else { return false }
        syncedAgentsEnabled = enabled
        // The files are written in the background, in switch order.
        agentIntegrationQueue.async {
            let fm = FileManager.default
            guard enabled else {
                fm.createFile(atPath: agentsDisabledFlagPath, contents: Data())
                return
            }
            try? fm.removeItem(atPath: agentsDisabledFlagPath)
            installMCPLauncher()
            for adapter in AgentKind.adapters {
                adapter.installIntegration()
            }
        }
        return true
    }

    private static let agentIntegrationQueue = DispatchQueue(label: "boo.agent-integration", qos: .utility)

    // MARK: - Codex

    /// Adds Boo's hook as Codex's `notify` program in ~/.codex/config.toml, so
    /// Boo sees when a Codex turn ends. Codex takes one notify program: an
    /// existing one is left alone. Skipped while Codex was never set up.
    static func installCodexNotify() {
        let codexDir = NSHomeDirectory().appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir) else { return }
        let configPath = codexDir.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let hook = agentHookPath
        guard let merged = mergingCodexNotify(hook: hook, into: existing) else { return }
        try? merged.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Codex lifecycle hooks the agent hook reports to Boo's agent inbox, plus
    /// SessionStart, where it tells the agent about the `boo` CLI.
    static let codexHookEvents = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"
    ]

    /// Adds Boo's hook to ~/.codex/hooks.json for every event in
    /// `codexHookEvents`, so Boo sees when Codex works, waits for a permission
    /// and finishes. `notify` alone only reports finished turns, and only while
    /// no other program holds it. Codex asks the user to review new hooks once
    /// (`/hooks`) before it runs them. Skipped while Codex was never set up.
    static func installCodexHooks() {
        let codexDir = NSHomeDirectory().appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir) else { return }
        let path = codexDir.appendingPathComponent("hooks.json")
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            // Never overwrite a file we can't read back.
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            root = parsed
        }
        guard
            let merged = mergingClaudeHook(
                command: codexHookCommand, into: root, events: codexHookEvents, matchers: [:], async: false,
                timeout: 3),
            let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        else { return }
        AgentIntegrationFiles.write(data, to: path)
    }

    /// The command Codex's hooks run: the payload comes on stdin.
    static var codexHookCommand: String { shellEscape(agentHookPath) + " codex-hooks" }

    /// `toml` with `notify = [hook, "codex"]` as its first line; nil when it
    /// already sets a top-level `notify` (ours or another program's).
    static func mergingCodexNotify(hook: String, into toml: String) -> String? {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }  // a table: top-level keys end here
            if trimmed.hasPrefix("notify"),
                trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
            {
                return nil
            }
        }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let line = "# Boo agent inbox: reports when a Codex turn ends.\nnotify = [\(quoted(hook)), \"codex\"]\n"
        return toml.isEmpty ? line : line + "\n" + toml
    }

    // MARK: - OpenCode

    /// Boo's plugin in OpenCode's global plugin folder: reports OpenCode's
    /// state to the agent inbox and tells it about the `boo` CLI. Skipped while
    /// OpenCode was never set up.
    static func installOpenCodePlugin() {
        let fm = FileManager.default
        let root = NSHomeDirectory().appendingPathComponent(".config/opencode")
        guard fm.fileExists(atPath: root),
            let plugin = AgentIntegrationFiles.bundled("boo-opencode-plugin.js")
        else { return }
        // Current OpenCode reads plugins/; older releases plugin/.
        let legacy = root.appendingPathComponent("plugin")
        let dir =
            fm.fileExists(atPath: legacy) && !fm.fileExists(atPath: root.appendingPathComponent("plugins"))
            ? legacy : root.appendingPathComponent("plugins")
        AgentIntegrationFiles.write(plugin, to: dir.appendingPathComponent("boo.js"))
    }
}
