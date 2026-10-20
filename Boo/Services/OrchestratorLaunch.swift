import Foundation

/// What survives a relaunch: the Claude conversation to resume and the
/// worktrees of the tasks it started (tab IDs do not survive, folders do).
struct OrchestratorSession: Codable, Sendable, Equatable {
    var sessionID: String?
    var ownedWorktrees: [String] = []
}

/// Builds the orchestrator's `claude` command line and its MCP config.
enum OrchestratorLaunch {
    /// `~/.boo/orchestrator`, where Boo writes the MCP config.
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".boo/orchestrator", isDirectory: true)
    }

    /// The bundled system prompt.
    static var promptURL: URL? {
        BooResourceBundle.bundle.url(forResource: "prompt", withExtension: "md", subdirectory: "Orchestrator")
    }

    /// Long enough for `wait_for_events` to hold its reply.
    static let toolTimeoutMillis = 600_000

    /// An MCP config with only Boo's server, started as `<executable> --mcp`.
    /// It inherits `BOO_SOCK`, `BOO_PANE_ID` and `BOO_TOKEN` from the terminal.
    static func mcpConfig(executable: String) -> Data {
        let config: [String: Any] = ["mcpServers": ["boo": ["command": executable, "args": ["--mcp"]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes the MCP config into `directory` and returns its path.
    static func writeMCPConfig(executable: String, directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mcp.json")
        try mcpConfig(executable: executable).write(to: url, options: .atomic)
        return url
    }

    /// The line typed into the orchestrator's shell. `exec` makes Claude's exit
    /// end the terminal, so the drawer can offer Resume / New conversation.
    /// `notice` is echoed first (e.g. why a resume became a new conversation).
    static func command(
        sessionID: String, resume: Bool, mcpConfig: String, promptFile: String, notice: String? = nil
    ) -> String {
        let session = resume ? "--resume \(quote(sessionID))" : "--session-id \(quote(sessionID))"
        var line =
            "exec claude \(session) --mcp-config \(quote(mcpConfig))"
            + " --append-system-prompt \"$(cat \(quote(promptFile)))\""
        if let notice { line = "echo \(quote(notice)); " + line }
        return line
    }

    static func spec(command: String, cwd: String? = nil) -> LaunchSpec {
        LaunchSpec(command: command, cwd: cwd, env: ["MCP_TOOL_TIMEOUT": String(toolTimeoutMillis)])
    }

    /// Single-quotes `value` for POSIX shells and fish.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether `claude` is on the user's login-shell PATH. Unknown counts as yes,
    /// so a broken check never hides the start button.
    static func claudeInstalled() async -> Bool {
        await Task.detached(priority: .utility) {
            let env = ProcessInfo.processInfo.environment
            let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "command -v claude"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return true }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
