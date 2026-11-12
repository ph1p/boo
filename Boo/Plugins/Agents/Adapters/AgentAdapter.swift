import Foundation

/// Everything Boo knows about one coding-agent CLI: names, how to spot it in
/// the process tree, how to start, continue and resume it, its config files
/// and the hook that reports its state to the agent inbox.
///
/// Adding an agent:
/// 1. Add a case to `AgentKind` (its raw value is persisted: never rename it).
/// 2. Write a type conforming to `AgentAdapter` in this folder.
/// 3. Add it to `AgentKind.adapters` and place it in `AgentKind.detectionOrder`.
/// 4. Add its command to `_BOO_AGENT_CMDS` in boo.bash, boo.zsh and boo.fish.
protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// Full name for menus and settings ("Claude Code").
    var displayName: String { get }
    /// Short name for tabs and pickers ("Claude").
    var shortName: String { get }
    /// The name the socket, `boo run --agent`, the MCP server and inbox rows
    /// use (default: `binary`).
    var ipcName: String { get }
    /// Lowercased `agent_kind` metadata values that mean this agent.
    var aliases: Set<String> { get }

    /// The command the user types; also the process name that means this agent.
    var binary: String { get }
    /// Substrings of the argv of a script runtime (node, python...) running
    /// this agent. Checked in `AgentKind.detectionOrder`.
    var argvPatterns: [String] { get }
    /// Whole words in a terminal title that mean this agent runs.
    var titleKeywords: [String] { get }

    /// How a prompt reaches a new or resumed session.
    var promptStyle: AgentPromptStyle { get }
    /// The command without a prompt.
    func baseCommand(_ invocation: AgentInvocation) -> String

    /// Config files shown in the agents sidebar, project files first.
    var configFiles: [AgentConfigFileSpec] { get }
    /// Adds config the file list can't express (skills, named sub-agents).
    func scanExtraConfig(root: String, home: String, into config: inout AgentsPlugin.AgentConfig)

    /// Installs or updates the hook that reports this agent's state to Boo.
    /// Runs on a background queue while agents are on; skips agents never set up.
    func installIntegration()
}

/// What a launch asks the agent to do.
enum AgentInvocation: Equatable {
    /// A new session, with `model` when one was picked.
    case start(model: String?)
    /// The most recent session in the folder.
    case continueLast
    /// One session by its ID.
    case resume(sessionID: String)
}

/// How a prompt reaches the agent's first message.
enum AgentPromptStyle: Equatable {
    /// `agent <prompt>`
    case positional
    /// `agent <flag> <prompt>`
    case flag(String)
    /// `_BOO_FIRST_PROMPT=<prompt> agent`: the agent has no flag for an
    /// interactive start with a prompt; Boo's plugin types it in.
    case firstPromptEnv
}

/// One config file of an agent, relative to the project root or the home folder.
struct AgentConfigFileSpec: Equatable {
    let path: String
    let name: String
    let icon: String
    let global: Bool

    static func project(_ path: String, _ name: String, icon: String = "gearshape") -> Self {
        Self(path: path, name: name, icon: icon, global: false)
    }

    static func global(_ path: String, _ name: String, icon: String = "gearshape") -> Self {
        Self(path: path, name: name, icon: icon, global: true)
    }
}

extension AgentAdapter {
    var ipcName: String { binary }
    var aliases: Set<String> { [binary, kind.rawValue] }
    var argvPatterns: [String] { [binary] }
    var titleKeywords: [String] { [] }
    var promptStyle: AgentPromptStyle { .positional }
    var configFiles: [AgentConfigFileSpec] { [] }
    func scanExtraConfig(root: String, home: String, into config: inout AgentsPlugin.AgentConfig) {}
    func installIntegration() {}

    /// The full shell command for `invocation`. `prompt` is already a shell
    /// word: quoted text or a `"$VAR"` reference.
    func command(_ invocation: AgentInvocation, prompt: String? = nil) -> String {
        let base = baseCommand(invocation)
        guard let prompt, !prompt.isEmpty else { return base }
        switch promptStyle {
        case .positional: return base + " " + prompt
        case .flag(let flag): return base + " " + flag + " " + prompt
        case .firstPromptEnv: return AgentKind.firstPromptEnvKey + "=" + prompt + " " + base
        }
    }

    /// `--model <model>` with a leading space, or "" without a model.
    func modelFlag(_ model: String?, flag: String = "--model") -> String {
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return "" }
        return " " + flag + " " + shellQuoted(model)
    }
}

// MARK: - Integration helpers

enum AgentIntegrationFiles {
    /// A file shipped in the app's shell-integration resources.
    static func bundled(_ name: String) -> Data? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        return FileManager.default.contents(atPath: resources.appendingPathComponent("shell-integration/" + name))
    }

    /// Writes `data` to `path` unless it already has that content.
    static func write(_ data: Data, to path: String) {
        let fm = FileManager.default
        guard fm.contents(atPath: path) != data else { return }
        try? fm.createDirectory(atPath: path.deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: data)
    }
}
