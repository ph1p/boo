import Foundation

/// A coding agent Boo knows. The raw value is persisted (sessions, settings):
/// never rename one. Per-agent behavior lives in its `AgentAdapter`.
enum AgentKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case copilot
    case pi
    case hermes
    case custom

    /// Every agent's adapter, built once, in `allCases` order.
    static let adapters: [any AgentAdapter] = [
        ClaudeCodeAdapter(), CodexAdapter(), OpenCodeAdapter(), CopilotAdapter(), PiAdapter(), HermesAdapter()
    ]

    private static let adapterByKind = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })

    /// The agent's adapter; nil for `.custom`, an unknown AI process.
    var adapter: (any AgentAdapter)? { Self.adapterByKind[self] }

    /// The order argv and terminal titles are matched in: specific names
    /// first, since `hermes -m anthropic/claude-...` also contains "claude".
    static let detectionOrder: [AgentKind] = [.hermes, .pi, .copilot, .codex, .openCode, .claudeCode]

    /// The env var Hermes' Boo plugin reads its first prompt from.
    static let firstPromptEnvKey = "_BOO_FIRST_PROMPT"

    var displayName: String { adapter?.displayName ?? "AI Agent" }

    var shortName: String { adapter?.shortName ?? "Agent" }

    /// The agents a task or helper can start, in picker order.
    static let taskKinds: [AgentKind] = adapters.map(\.kind)

    /// The name the socket, `boo run --agent` and inbox rows use ("claude" for Claude Code).
    var ipcName: String { adapter?.ipcName ?? rawValue }

    init?(ipcName: String) {
        guard let kind = Self.taskKinds.first(where: { $0.ipcName == ipcName }) else { return nil }
        self = kind
    }

    /// "claude, codex, opencode, ..." for help texts and errors.
    static let ipcNameList = taskKinds.map(\.ipcName).joined(separator: ", ")

    /// "claude, codex, ... or hermes": the commands that start each agent.
    static let binaryList: String = {
        let binaries = adapters.map(\.binary)
        return binaries.dropLast().joined(separator: ", ") + " or " + (binaries.last ?? "")
    }()

    /// `agent_kind` metadata values and process names, to their agent.
    private static let byAlias: [String: AgentKind] = Dictionary(
        adapters.flatMap { a in a.aliases.map { ($0, a.kind) } }, uniquingKeysWith: { first, _ in first })
    private static let byBinary = Dictionary(uniqueKeysWithValues: adapters.map { ($0.binary, $0.kind) })

    static func infer(processName: String, metadata: [String: String]) -> AgentKind? {
        if let raw = metadata["agent_kind"]?.lowercased(), let kind = byAlias[raw] { return kind }
        return byBinary[processName.lowercased()]
    }
}

enum AgentRunState: String, Equatable {
    case running
    case idle
    case needsInput = "needs-input"
    case unknown

    var displayName: String {
        switch self {
        case .running: return "running"
        case .idle: return "idle"
        case .needsInput: return "needs input"
        case .unknown: return "unknown"
        }
    }
}

struct AgentSession: Equatable {
    let kind: AgentKind
    let displayName: String
    let processName: String
    let pid: pid_t?
    let cwd: String
    let startedAt: Date
    let state: AgentRunState
    let sessionID: String?
    let transcriptPath: String?
    let model: String?
    let mode: String?
    let metadata: [String: String]
}

struct WorkspaceAgentSession: Identifiable, Equatable {
    let id: UUID
    let paneID: UUID
    let tabID: UUID
    let tabTitle: String
    let isFocused: Bool
    let agent: AgentSession
}

// MARK: - Agent Binary Detection

enum AgentBinaryScanner {
    /// Returns the subset of AgentKind whose CLI binary is found on disk.
    /// .custom is always excluded (no associated binary).
    static func detectInstalledAgents() -> Set<AgentKind> {
        Set(AgentKind.adapters.filter { BinaryScanner.isInstalled($0.binary) }.map(\.kind))
    }
}
