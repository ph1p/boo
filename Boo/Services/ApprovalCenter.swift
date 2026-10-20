import Foundation

extension Notification.Name {
    static let approvalsChanged = Notification.Name("BooApprovalsChanged")
}

/// Commands from a gated caller (the orchestrator) waiting for the user.
///
/// The caller gets `{status: "pending", approval_id}` right away; the outcome
/// comes later through `onResolved` (the `approval_resolved` event). A card
/// remembers each target's inbox `updated_at`: if the agent moved on or its
/// tab closed before the user decided, the card resolves `stale` and nothing
/// is sent. Cards never time out into "allowed".
@MainActor
final class ApprovalCenter {
    static let shared = ApprovalCenter()

    enum Outcome: String {
        case allowed, denied, stale
    }

    struct Request: Identifiable {
        let id: UUID
        let cmd: String
        let json: [String: Any]
        let callerTabID: UUID
        let targetTabIDs: [UUID]
        /// "Type into pane", "Merge task", …
        let action: String
        /// Exactly what would be sent: the text, the key, the answer.
        let payload: String
        /// Whether "Allow for this pane" is offered (never for merge or discard).
        let allowsTabGrant: Bool
        let createdAt: Date
        /// Each target's inbox `updated_at` when the card was made (nil: not in the inbox).
        let stamps: [UUID: Double?]
    }

    private(set) var pending: [Request] = []
    /// Tabs the user allowed a caller to write to, for this app session.
    private var grants: [UUID: Set<UUID>] = [:]

    /// Inbox `updated_at` of a tab, nil when the tab has no agent item.
    var stamp: (UUID) -> Double? = { AgentInbox.shared.items[$0]?.updatedAt.timeIntervalSince1970 }
    /// Whether a tab is still open somewhere.
    var tabExists: (UUID) -> Bool = { AgentInbox.shared.locate($0) != nil }
    /// Called once per request with its outcome and, when allowed, the command's reply.
    var onResolved: ((Request, Outcome, [String: Any]?) -> Void)?

    private var performers: [UUID: (@escaping ([String: Any]) -> Void) -> Void] = [:]
    private var inboxObserver: NSObjectProtocol?

    init() {}

    /// Re-checks pending cards whenever an agent changes state.
    func startObserving() {
        guard inboxObserver == nil else { return }
        inboxObserver = NotificationCenter.default.addObserver(
            forName: .agentInboxChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidate() }
        }
    }

    // MARK: - Queue

    /// Adds a card. `perform` runs the command when allowed and hands back its reply.
    @discardableResult
    func enqueue(
        cmd: String, json: [String: Any], caller: UUID, targets: [UUID],
        perform: @escaping (@escaping ([String: Any]) -> Void) -> Void
    ) -> Request {
        let request = Request(
            id: UUID(), cmd: cmd, json: json, callerTabID: caller, targetTabIDs: targets,
            action: Self.action(cmd: cmd, json: json), payload: Self.payload(cmd: cmd, json: json),
            allowsTabGrant: !OrchestratorGate.alwaysApproved.contains(cmd), createdAt: Date(),
            stamps: Dictionary(uniqueKeysWithValues: targets.map { ($0, stamp($0)) }))
        pending.append(request)
        performers[request.id] = perform
        changed()
        return request
    }

    /// The user's answer. `forTab` also allows later writes from this caller to these tabs.
    func resolve(_ id: UUID, allow: Bool, forTab: Bool = false) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        guard allow else {
            finish(request, .denied, reply: nil)
            return
        }
        guard !isStale(request) else {
            finish(request, .stale, reply: nil)
            return
        }
        if forTab && request.allowsTabGrant {
            grants[request.callerTabID, default: []].formUnion(request.targetTabIDs)
        }
        let perform = performers[id]
        take(request)
        guard let perform else {
            onResolved?(request, .allowed, nil)
            return
        }
        perform { [weak self] reply in
            self?.onResolved?(request, .allowed, reply)
        }
    }

    /// Resolves every card `stale` (relaunch, orchestrator gone).
    func expireAll() {
        for request in pending { finish(request, .stale, reply: nil) }
    }

    /// Resolves cards whose target changed or closed.
    func revalidate() {
        for request in pending where isStale(request) {
            finish(request, .stale, reply: nil)
        }
    }

    func isGranted(caller: UUID, tab: UUID) -> Bool {
        grants[caller]?.contains(tab) == true
    }

    func revokeGrants(tab: UUID) {
        grants.removeValue(forKey: tab)
        for key in grants.keys { grants[key]?.remove(tab) }
    }

    // MARK: - Private

    private func isStale(_ request: Request) -> Bool {
        request.targetTabIDs.contains { tab in
            !tabExists(tab) || !Self.sameStamp(request.stamps[tab] ?? nil, stamp(tab))
        }
    }

    private static func sameStamp(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a - b) <= 0.001
        default: return false
        }
    }

    private func finish(_ request: Request, _ outcome: Outcome, reply: [String: Any]?) {
        take(request)
        onResolved?(request, outcome, reply)
    }

    private func take(_ request: Request) {
        pending.removeAll { $0.id == request.id }
        performers.removeValue(forKey: request.id)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .approvalsChanged, object: self)
    }

    // MARK: - Card text

    static func action(cmd: String, json: [String: Any]) -> String {
        switch cmd {
        case "agent_respond":
            return (json["response"] as? String) == "deny" ? "Deny permission prompt" : "Approve permission prompt"
        case "send_text": return "Type into pane"
        case "send_key": return "Press a key in pane"
        case "close_pane": return "Close agent pane"
        case "merge_task": return "Merge task"
        case "discard_task": return "Discard task"
        default: return cmd
        }
    }

    static func payload(cmd: String, json: [String: Any]) -> String {
        switch cmd {
        case "agent_respond": return json["response"] as? String ?? ""
        case "send_text":
            let text = json["text"] as? String ?? ""
            return (json["submit"] as? Bool ?? false) ? text + " ⏎" : text
        case "send_key": return json["key"] as? String ?? ""
        case "merge_task", "discard_task": return json["summary"] as? String ?? ""
        default: return ""
        }
    }
}
