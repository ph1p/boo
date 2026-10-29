import Foundation

/// What happened to agents since the orchestrator last looked, for the
/// blocking `wait_for_events` socket command.
///
/// Events get a monotonic `seq`. A caller passes the last `seq` it saw as
/// `since`: pending events return at once, otherwise the reply is held until
/// one arrives or `timeout` passes (then `events` is empty). Only the newest
/// `capacity` events are kept; a caller that fell further behind gets
/// `missed: true` and should re-read the layout.
@MainActor
final class OrchestratorEvents {
    static let shared = OrchestratorEvents()

    struct Event {
        let seq: Int
        let type: String
        let data: [String: Any]
        let time: Date
    }

    nonisolated static let defaultTimeout: TimeInterval = 300
    /// Below the orchestrator's `MCP_TOOL_TIMEOUT` (600 s).
    nonisolated static let maxTimeout: TimeInterval = 540

    let capacity: Int
    private(set) var seq = 0
    private(set) var ring: [Event] = []

    private struct Waiter {
        let since: Int
        let reply: ([String: Any]) -> Void
    }
    private var waiters: [UUID: Waiter] = [:]

    /// Runs `body` after `delay` seconds (injectable for tests).
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
    }

    /// Inbox states last seen, to turn `.agentInboxChanged` into transitions.
    private var lastStates: [UUID: AgentInbox.State] = [:]
    private var inboxObserver: NSObjectProtocol?

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    // MARK: - Posting

    func post(_ type: String, _ data: [String: Any] = [:], now: Date = Date()) {
        seq += 1
        ring.append(Event(seq: seq, type: type, data: data, time: now))
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let ready = waiters
        waiters.removeAll()
        for waiter in ready.values { waiter.reply(response(since: waiter.since)) }
    }

    // MARK: - Waiting

    /// Replies with the events after `since`, waiting up to `timeout` seconds for one.
    func wait(since: Int, timeout: TimeInterval, reply: @escaping ([String: Any]) -> Void) {
        let since = since > seq ? 0 : since  // Boo relaunched: seq restarted
        if seq > since {
            reply(response(since: since))
            return
        }
        let id = UUID()
        waiters[id] = Waiter(since: since, reply: reply)
        schedule(min(max(timeout, 0), Self.maxTimeout)) { [weak self] in
            guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
            waiter.reply(self.response(since: waiter.since))
        }
    }

    func response(since: Int) -> [String: Any] {
        let events = ring.filter { $0.seq > since }
        let oldest = ring.first?.seq ?? seq + 1
        return [
            "ok": true, "seq": seq, "missed": since + 1 < oldest && since < seq,
            "events": events.map(Self.serialize)
        ]
    }

    /// `wait_for_events`: `{since?, timeout?}`.
    func handleSocketCommand(_ json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let since = (json["since"] as? Int) ?? seq
        let timeout = (json["timeout"] as? Double) ?? (json["timeout"] as? Int).map(Double.init) ?? Self.defaultTimeout
        wait(since: since, timeout: timeout, reply: reply)
    }

    private static func serialize(_ event: Event) -> [String: Any] {
        var object = event.data
        object["seq"] = event.seq
        object["type"] = event.type
        object["time"] = event.time.timeIntervalSince1970
        return object
    }

    // MARK: - Sources

    /// Feeds the ring from inbox changes and approval outcomes.
    func startObserving() {
        guard inboxObserver == nil else { return }
        lastStates = AgentInbox.shared.items.mapValues(\.state)
        inboxObserver = NotificationCenter.default.addObserver(
            forName: .agentInboxChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inboxChanged(AgentInbox.shared.items) }
        }
        ApprovalCenter.shared.onResolved = { [weak self] request, outcome, reply in
            self?.approvalResolved(request, outcome, reply)
        }
    }

    /// Posts `state_changed` (and `task_finished` for owned agents that stopped)
    /// for every tab whose state changed.
    func inboxChanged(_ items: [UUID: AgentInbox.Item], owner: UUID? = OrchestratorController.shared.tabID) {
        for (tabID, item) in items.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            let previous = lastStates[tabID]
            guard previous != item.state else { continue }
            OrchestratorLoopGuard.shared.reset(tabID)
            let owned = owner.map { CapabilityTokens.shared.owns($0, tabID) } ?? false
            var data: [String: Any] = [
                "tab_id": tabID.uuidString, "agent": item.agent, "state": item.state.rawValue,
                "previous": previous?.rawValue ?? NSNull(), "owned": owned,
                "updated_at": item.updatedAt.timeIntervalSince1970
            ]
            if let message = item.message { data["message"] = message }
            if let tool = item.tool { data["tool"] = tool }
            post("state_changed", data)
            BooSocketServer.shared.emitEvent(name: "agent_state_changed", data: data)
            if owned && (item.state == .done || item.state == .error) {
                post("task_finished", ["tab_id": tabID.uuidString, "state": item.state.rawValue])
            }
        }
        for tabID in lastStates.keys where items[tabID] == nil {
            let data: [String: Any] = [
                "tab_id": tabID.uuidString, "state": "ended", "previous": lastStates[tabID]?.rawValue ?? NSNull()
            ]
            post("state_changed", data)
            BooSocketServer.shared.emitEvent(name: "agent_state_changed", data: data)
        }
        lastStates = items.mapValues(\.state)
    }

    /// A tab's terminal closed. Tear-off closes and reopens it in another
    /// window, so this waits a tick and posts only when the tab is really gone.
    func terminalClosed(_ tabID: UUID, isGone: @escaping (UUID) -> Bool = { AgentInbox.locateInWindows($0) == nil }) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, isGone(tabID) else { return }
                self.tabGone(tabID)
            }
        }
    }

    func tabGone(_ tabID: UUID) {
        let owner = OrchestratorController.shared.tabID
        let owned = owner.map { CapabilityTokens.shared.owns($0, tabID) } ?? false
        CapabilityTokens.shared.disown(tabID)
        OrchestratorLoopGuard.shared.reset(tabID)
        ApprovalCenter.shared.revokeGrants(tab: tabID)
        post("pane_closed", ["tab_id": tabID.uuidString, "owned": owned])
        AgentInbox.shared.remove(tabID: tabID)
        RemoteAgentTracker.shared.forget(tabID: tabID)
    }

    private func approvalResolved(
        _ request: ApprovalCenter.Request, _ outcome: ApprovalCenter.Outcome, _ reply: [String: Any]?
    ) {
        var data: [String: Any] = [
            "approval_id": request.id.uuidString, "cmd": request.cmd, "outcome": outcome.rawValue,
            "tab_ids": request.targetTabIDs.map(\.uuidString)
        ]
        if let reply {
            data["result"] = reply["ok"] as? Bool == false ? "error" : "ok"
            if let error = reply["error"] as? String { data["error"] = error }
        }
        post("approval_resolved", data)
    }
}
