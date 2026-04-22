import Foundation

enum AgentKind: String, CaseIterable, Equatable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case custom

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .custom: return "AI Agent"
        }
    }

    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .custom: return "Agent"
        }
    }

    var processNames: Set<String> {
        switch self {
        case .claudeCode: return ["claude"]
        case .codex: return ["codex"]
        case .openCode: return ["opencode"]
        case .custom: return []
        }
    }

    static func infer(processName: String, metadata: [String: String]) -> AgentKind? {
        if let raw = metadata["agent_kind"]?.lowercased() {
            switch raw {
            case "claude", "claude-code", "claudecode":
                return .claudeCode
            case "codex":
                return .codex
            case "opencode", "open-code", "open_code":
                return .openCode
            default:
                break
            }
        }

        let process = processName.lowercased()
        return Self.allCases.first { $0.processNames.contains(process) }
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

struct AgentSetupRecommendation: Identifiable, Equatable {
    enum Status: String {
        case detected = "Detected"
        case enhanced = "Enhanced"
        case missing = "Missing setup"
    }

    let id = UUID()
    let kind: AgentKind
    let status: Status
    let title: String
    let detail: String
    let primaryAction: String?
}

struct AgentToolSummary: Identifiable, Equatable {
    let id = UUID()
    let kind: AgentKind
    let status: AgentSetupRecommendation.Status
    let configCount: Int
    let detail: String
}

// MARK: - Agent Binary Detection

enum AgentBinaryScanner {
    /// Returns the subset of AgentKind whose CLI binary is found on disk.
    /// .custom is always excluded (no associated binary).
    static func detectInstalledAgents() -> Set<AgentKind> {
        var found = Set<AgentKind>()
        for kind in AgentKind.allCases where kind != .custom {
            if kind.processNames.contains(where: { BinaryScanner.isInstalled($0) }) {
                found.insert(kind)
            }
        }
        return found
    }
}
