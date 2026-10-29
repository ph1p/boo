import Foundation

/// Feeds `AgentInbox` for coding agents running on the far side of an ssh/mosh
/// session, where Boo's agent hooks can't reach (the hook talks to the local
/// socket) and the process tree only shows `ssh`.
///
/// The only signals that cross the connection are the window title and bells /
/// desktop notifications, so this reads those:
/// - title starting with a spinner glyph (Braille, ◐…) → working
/// - title starting with ✳ (Claude's idle mark) → done
/// - bell or OSC 9/777 notification while tracked → needs-input
/// - title no longer an agent's → the item is removed
///
/// Tabs with a hook-fed inbox item are left alone: the hooks are the better source.
@MainActor
final class RemoteAgentTracker {
    static let shared = RemoteAgentTracker()

    /// Raw values are the inbox events they map to.
    enum TitleState: String {
        case working
        case idle = "done"
    }

    /// Foreground processes that put the agent on another machine.
    static let remoteProcesses: Set<String> = ["ssh", "mosh", "mosh-client", "autossh", "et"]

    let inbox: AgentInbox
    /// True when the shell's foreground process is a remote session client.
    let isRemoteShell: (pid_t) -> Bool

    /// Tabs this tracker owns an inbox item for, with the last state read from the title.
    private(set) var tracked: [UUID: TitleState] = [:]

    init(
        inbox: AgentInbox = .shared,
        isRemoteShell: @escaping (pid_t) -> Bool = { pid in
            guard pid > 0, let name = ProcessTree.foregroundProcess(shellPID: pid) else { return false }
            return RemoteAgentTracker.remoteProcesses.contains(name)
        }
    ) {
        self.inbox = inbox
        self.isRemoteShell = isRemoteShell
    }

    /// The agent and state a title shows, or nil when it isn't an agent's title.
    static func parse(title: String) -> (agent: String, state: TitleState?)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let agent = ProcessIcon.matchTitle(trimmed), ProcessIcon.category(for: agent) == "ai",
            let first = trimmed.unicodeScalars.first
        else { return nil }
        if first.value == 0x2733 { return (agent, .idle) }
        return (agent, ProcessIcon.isAISpinnerScalar(first) ? .working : nil)
    }

    func titleChanged(tabID: UUID, title: String, shellPID: pid_t) {
        guard let parsed = Self.parse(title: title) else {
            end(tabID: tabID)
            return
        }
        // A title without a status glyph says nothing about the state.
        guard let state = parsed.state else { return }
        if tracked[tabID] == nil {
            // Only remote tabs no hook reports for.
            guard inbox.items[tabID] == nil, isRemoteShell(shellPID) else { return }
        } else if tracked[tabID] == state {
            return
        }
        tracked[tabID] = state
        // The idle mark also shows while a prompt waits: keep needs-input until work resumes.
        if state == .idle, inbox.items[tabID]?.state == .needsInput { return }
        inbox.apply(event: state.rawValue, tabID: tabID, agent: parsed.agent)
    }

    /// A bell or desktop notification from the tab: the agent asks for the user.
    func attentionRequested(tabID: UUID, message: String? = nil) {
        guard tracked[tabID] != nil, let item = inbox.items[tabID] else { return }
        inbox.apply(event: "needs-input", tabID: tabID, agent: item.agent, message: message)
    }

    func end(tabID: UUID) {
        guard tracked.removeValue(forKey: tabID) != nil else { return }
        inbox.apply(event: "end", tabID: tabID)
    }

    /// The tab closed: its inbox item goes with it, so only the entry is dropped.
    func forget(tabID: UUID) {
        tracked[tabID] = nil
    }
}
