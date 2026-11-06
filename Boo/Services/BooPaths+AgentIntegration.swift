import Foundation

/// Wires Boo into the coding agents (Claude Code, Codex, OpenCode) while the
/// agents switch is on. Off: nothing is installed or updated, and a flag file
/// makes the hooks already installed exit at once.
extension BooPaths {
    /// Present while agents are off; the agent hooks check it and stay quiet.
    static var agentsDisabledFlagPath: String {
        configDir.appendingPathComponent("agents-disabled")
    }

    /// The agents switch the last sync applied; nil before the first one.
    nonisolated(unsafe) private static var syncedAgentsEnabled: Bool?

    /// Applies the agents switch: on installs or updates the hooks, the
    /// OpenCode plugin and the MCP/CLI launchers; off only writes the flag file.
    /// Cheap to call again: does nothing while the switch is unchanged.
    /// True when the switch changed since the last sync.
    @discardableResult
    static func syncAgentIntegration(enabled: Bool = AppSettings.shared.agentsEnabled) -> Bool {
        guard syncedAgentsEnabled != enabled else { return false }
        syncedAgentsEnabled = enabled
        let fm = FileManager.default
        guard enabled else {
            fm.createFile(atPath: agentsDisabledFlagPath, contents: Data())
            return true
        }
        try? fm.removeItem(atPath: agentsDisabledFlagPath)
        installMCPLauncher()
        installClaudeHook()
        installCodexNotify()
        installOpenCodePlugin()
        return true
    }

    // MARK: - Codex

    /// Adds Boo's hook as Codex's `notify` program in ~/.codex/config.toml, so
    /// Boo sees when a Codex turn ends. Codex takes one notify program: an
    /// existing one is left alone. Skipped while Codex was never set up.
    static func installCodexNotify() {
        let codexDir = NSHomeDirectory().appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir) else { return }
        let configPath = codexDir.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let hook = shellIntegrationDir.appendingPathComponent("boo-claude-hook")
        guard let merged = mergingCodexNotify(hook: hook, into: existing) else { return }
        try? merged.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

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
            let resources = Bundle.main.resourcePath
        else { return }
        let source = resources.appendingPathComponent("shell-integration/boo-opencode-plugin.js")
        guard let plugin = fm.contents(atPath: source) else { return }
        // Current OpenCode reads plugins/; older releases plugin/.
        let legacy = root.appendingPathComponent("plugin")
        let dir =
            fm.fileExists(atPath: legacy) && !fm.fileExists(atPath: root.appendingPathComponent("plugins"))
            ? legacy : root.appendingPathComponent("plugins")
        let target = dir.appendingPathComponent("boo.js")
        guard fm.contents(atPath: target) != plugin else { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: target, contents: plugin)
    }
}
