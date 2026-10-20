import Foundation

/// Stops the orchestrator from talking to an agent that does not react: after
/// `AgentTimeline.loopThreshold` writes to the same agent with no state change
/// in between, the next write needs the user's approval ("possible loop").
@MainActor
final class OrchestratorLoopGuard {
    static let shared = OrchestratorLoopGuard()

    /// Commands that write into an agent.
    static let writeCommands: Set<String> = ["agent_respond", "send_text", "send_key"]

    private var writes: [UUID: Int] = [:]

    init() {}

    /// Counts a write to `tabs`; true when it is one too many and must be approved.
    func record(_ tabs: [UUID]) -> Bool {
        let tripped = tabs.contains { writes[$0, default: 0] >= AgentTimeline.loopThreshold }
        if tripped { return true }
        for tab in tabs { writes[tab, default: 0] += 1 }
        return false
    }

    /// The agent changed state (or the user allowed the write): count afresh.
    func reset(_ tab: UUID) {
        writes.removeValue(forKey: tab)
    }

    func count(_ tab: UUID) -> Int { writes[tab, default: 0] }
}
