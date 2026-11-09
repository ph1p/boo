import Foundation

/// Feeds `AgentInbox` for coding agents running on the far side of an ssh/mosh
/// session, where Boo's agent hooks can't reach (the hook talks to the local
/// socket) and the process tree only shows `ssh`.
///
/// The only signals that cross the connection are the window title and bells /
/// desktop notifications, so this reads those:
/// - title starting with a spinner glyph (Braille, ◐…) → working
/// - title starting with ✳ (Claude's idle mark) → done
/// - bell or OSC 9/777 notification while tracked → needs-input (as a question: no Allow / Deny)
/// - title no longer an agent's → the item is removed
///
/// Tabs with a hook-fed inbox item are left alone: the hooks are the better source.
/// One exception: Claude fires no Stop hook when the user interrupts a turn
/// (Esc), so a hook-fed item would stay working. When its title goes from a
/// spinner to the idle mark and no hook has reported within a grace period,
/// the item is marked done (seen, no notification).
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
    /// Last title state of hook-fed tabs, to catch an interrupt (spinner → idle).
    private var hookTitles: [UUID: TitleState] = [:]

    /// Wait before an idle title overrules a working hook item: a normal turn's
    /// Stop hook can land after the title change and must win (it carries the reply).
    static let interruptGrace: TimeInterval = 2
    /// Runs the interrupt check after a delay; injectable for tests.
    let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        inbox: AgentInbox = .shared,
        isRemoteShell: @escaping (pid_t) -> Bool = { pid in
            guard pid > 0, let name = ProcessTree.foregroundProcess(shellPID: pid) else { return false }
            return RemoteAgentTracker.remoteProcesses.contains(name)
        },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    ) {
        self.inbox = inbox
        self.isRemoteShell = isRemoteShell
        self.schedule = schedule
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
            hookTitles[tabID] = nil
            end(tabID: tabID)
            return
        }
        // A title without a status glyph says nothing about the state.
        guard let state = parsed.state else { return }
        if tracked[tabID] == nil {
            if let item = inbox.items[tabID] {
                hookTitleChanged(tabID: tabID, state: state, item: item)
                return
            }
            // Remember it: the hook item may arrive mid-turn.
            hookTitles[tabID] = state
            // Only remote tabs no hook reports for.
            guard isRemoteShell(shellPID) else { return }
        } else if tracked[tabID] == state {
            return
        }
        let wasWorking = tracked[tabID] == .working
        tracked[tabID] = state
        // The idle mark also shows while a prompt waits: keep needs-input until work resumes.
        if state == .idle, inbox.items[tabID]?.state == .needsInput { return }
        // A finished turn gets the tab dot and notification hooked agents get;
        // the bell path below already has its own. An agent first seen idle
        // (ssh attach, launch) finished nothing.
        if inbox.apply(event: state.rawValue, tabID: tabID, agent: parsed.agent) == .done, wasWorking {
            inbox.signalAttention(tabID: tabID)
        }
    }

    /// A bell or desktop notification from the tab: the agent asks for the user.
    /// Sent as a question: nothing tells a permission prompt from a question
    /// here, and Allow (Return) would pick a question's first option.
    func attentionRequested(tabID: UUID, message: String? = nil) {
        guard tracked[tabID] != nil, let item = inbox.items[tabID] else { return }
        inbox.apply(event: "question", tabID: tabID, agent: item.agent, message: message)
    }

    func end(tabID: UUID) {
        guard tracked.removeValue(forKey: tabID) != nil else { return }
        inbox.apply(event: "end", tabID: tabID)
    }

    /// The tab closed: its inbox item goes with it, so only the entry is dropped.
    func forget(tabID: UUID) {
        tracked[tabID] = nil
        hookTitles[tabID] = nil
    }

    /// A hook-fed tab's title went idle after a spinner while its item is still
    /// working: the user interrupted the turn. Settle it once the grace passes
    /// without a newer hook event.
    private func hookTitleChanged(tabID: UUID, state: TitleState, item: AgentInbox.Item) {
        let previous = hookTitles.updateValue(state, forKey: tabID)
        guard state == .idle, previous == .working, item.state == .working else { return }
        let stamp = item.updatedAt
        schedule(Self.interruptGrace) { [weak self] in
            guard let self, self.hookTitles[tabID] == .idle,
                let current = self.inbox.items[tabID], current.state == .working, current.updatedAt == stamp
            else { return }
            self.inbox.apply(event: "stop", tabID: tabID, agent: current.agent)
            self.inbox.markSeen(tabID: tabID)
        }
    }
}
