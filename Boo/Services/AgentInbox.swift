import Cocoa

extension Notification.Name {
    static let agentInboxChanged = Notification.Name("BooAgentInboxChanged")
}

/// App-wide list of coding agents and what each one is waiting for, fed by
/// agent hooks over the socket (`agent_event`). Spans every window, so one
/// place shows which agent needs an answer and jumps to its tab.
@MainActor
final class AgentInbox {
    static let shared = AgentInbox()

    enum State: String {
        case working
        /// Blocked on the user: a permission prompt or a question.
        case needsInput = "needs-input"
        /// Finished its turn.
        case done
        case error
    }

    struct Item: Identifiable, Equatable {
        /// Terminal tab the agent runs in (tabs keep their ID across panes and windows).
        let tabID: UUID
        var agent: String
        var state: State
        var message: String?
        var tool: String?
        var sessionID: String?
        var cwd: String?
        var updatedAt: Date
        /// The user looked at the tab since the agent stopped.
        var seen: Bool

        var id: UUID { tabID }

        /// Waiting for the user and not yet looked at (needs-input always waits).
        var needsAttention: Bool {
            switch state {
            case .needsInput: return true
            case .done, .error: return !seen
            case .working: return false
            }
        }
    }

    /// Where a tab currently lives.
    struct Location {
        let controller: MainWindowController
        let workspace: Workspace
        let pane: Pane
        let tabIndex: Int
    }

    private(set) var items: [UUID: Item] = [:]
    /// The orchestrator's own session; never in `items`.
    private(set) var orchestrator: Item?
    /// The orchestrator's tab and pane (its hooks report like any agent's).
    var orchestratorTabID: () -> UUID? = { OrchestratorController.shared.tabID }
    var orchestratorPaneID: () -> UUID? = { OrchestratorController.shared.paneID }
    /// Resolves a tab to its window, workspace and pane; nil once the tab is gone.
    var locate: (UUID) -> Location? = { AgentInbox.locateInWindows($0) }
    /// Reads the screen of a tab's terminal; for the remote page's previews.
    var readScreen: (UUID) -> String? = { AgentInbox.terminalView(ofTab: $0)?.readViewportText() }
    /// Types an answer into a tab's terminal; false when it is not open.
    var sendResponse: (UUID, Response) -> Bool = { tabID, response in
        guard let view = AgentInbox.terminalView(ofTab: tabID) else { return false }
        AgentInbox.sendResponse(response, to: view)
        return true
    }
    /// Pastes a message into a tab's terminal and submits it; false when it is not open.
    var sendMessage: (UUID, String) -> Bool = { tabID, text in
        guard let view = AgentInbox.terminalView(ofTab: tabID) else { return false }
        view.paste(text, submit: true)
        return true
    }

    init() {}

    /// Attention first (needs-input, then unseen done/error), then most recent.
    var sortedItems: [Item] {
        items.values.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if (a.state == .needsInput) != (b.state == .needsInput) { return a.state == .needsInput }
            return a.updatedAt > b.updatedAt
        }
    }

    var attentionCount: Int { items.values.filter(\.needsAttention).count }

    /// Every status bar redraws from this.
    private func changed() {
        NotificationCenter.default.post(name: .agentInboxChanged, object: self)
    }

    // MARK: - Events

    /// Applies one hook event. Returns the item's new state when the agent now
    /// waits for the user (so the caller can notify), nil otherwise.
    @discardableResult
    func apply(
        event: String, tabID: UUID, agent: String = "claude", message: String? = nil,
        tool: String? = nil, sessionID: String? = nil, cwd: String? = nil, now: Date = Date()
    ) -> State? {
        if event == "end" {
            remove(tabID: tabID)
            return nil
        }
        let previous = items[tabID]?.state
        guard
            let item = Self.updated(
                items[tabID], event: event, tabID: tabID, agent: agent, message: message, tool: tool,
                sessionID: sessionID, cwd: cwd, now: now)
        else { return nil }
        items[tabID] = item
        changed()
        return item.needsAttention && item.state != previous ? item.state : nil
    }

    /// Applies a hook event from the orchestrator's own session. Kept out of
    /// `items`: the orchestrator is not an agent to triage, it only drives the
    /// drawer's status.
    func applyOrchestrator(
        event: String, tabID: UUID, message: String? = nil, tool: String? = nil,
        sessionID: String? = nil, cwd: String? = nil, now: Date = Date()
    ) {
        if event == "end" {
            guard orchestrator != nil else { return }
            orchestrator = nil
        } else {
            guard
                let item = Self.updated(
                    orchestrator, event: event, tabID: tabID, agent: "claude", message: message, tool: tool,
                    sessionID: sessionID, cwd: cwd, now: now)
            else { return }
            orchestrator = item
        }
        changed()
    }

    /// `existing` after one hook event; nil for events that change nothing.
    private static func updated(
        _ existing: Item?, event: String, tabID: UUID, agent: String, message: String?,
        tool: String?, sessionID: String?, cwd: String?, now: Date
    ) -> Item? {
        let state: State
        switch event {
        case "prompt", "tool", "working": state = .working
        case "permission", "question", "needs-input": state = .needsInput
        case "stop", "done": state = .done
        case "error": state = .error
        default: return nil
        }
        var item = existing ?? Item(tabID: tabID, agent: agent, state: state, updatedAt: now, seen: false)
        let previous = existing?.state
        item.agent = agent
        item.state = state
        item.updatedAt = now
        item.sessionID = sessionID ?? item.sessionID
        item.cwd = cwd ?? item.cwd
        switch state {
        case .working:
            item.tool = tool ?? item.tool
            item.message = nil
        case .needsInput, .done, .error:
            item.message = message
            if state != previous { item.seen = false }
        }
        return item
    }

    /// The user is looking at `tabID`: done/error stop asking for attention.
    func markSeen(tabID: UUID) {
        guard var item = items[tabID], !item.seen else { return }
        item.seen = true
        items[tabID] = item
        changed()
    }

    func remove(tabID: UUID) {
        guard items.removeValue(forKey: tabID) != nil else { return }
        changed()
    }

    /// Drops items whose tab no longer exists.
    func prune() {
        let gone = items.keys.filter { locate($0) == nil }
        guard !gone.isEmpty else { return }
        for id in gone { items.removeValue(forKey: id) }
        changed()
    }

    // MARK: - Jumping

    /// Bring the tab's window forward and focus the tab.
    @discardableResult
    func jump(to tabID: UUID) -> Bool {
        guard let location = locate(tabID) else {
            remove(tabID: tabID)
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        location.controller.window?.makeKeyAndOrderFront(nil)
        location.controller.focusActivity(
            workspaceID: location.workspace.id, paneID: location.pane.id, tabIndex: location.tabIndex)
        markSeen(tabID: tabID)
        return true
    }

    /// Jump to the first item waiting for the user.
    @discardableResult
    func jumpToNextAttention() -> Bool {
        prune()
        guard let next = sortedItems.first(where: \.needsAttention) else { return false }
        return jump(to: next.tabID)
    }

    static func locateInWindows(_ tabID: UUID) -> Location? {
        for controller in WindowManager.shared.controllers {
            for workspace in controller.appState.workspaces {
                for pane in workspace.panes.values {
                    if let index = pane.tabs.firstIndex(where: { $0.id == tabID }) {
                        return Location(controller: controller, workspace: workspace, pane: pane, tabIndex: index)
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Socket

extension AgentInbox {
    /// `agent_event`: `{tab_id | pane_id, event, agent?, message?, tool?, session_id?, cwd?}`.
    /// A bare `pane_id` resolves to that pane's active tab.
    func handleSocketEvent(_ json: [String: Any]) -> [String: Any] {
        guard let event = json["event"] as? String else { return ["ok": false, "error": "missing event"] }
        if let tabID = orchestratorTab(json) {
            applyOrchestrator(
                event: event, tabID: tabID, message: Self.nonEmpty(json["message"]), tool: Self.nonEmpty(json["tool"]),
                sessionID: Self.nonEmpty(json["session_id"]), cwd: Self.nonEmpty(json["cwd"]))
            return ["ok": true, "state": orchestrator?.state.rawValue ?? NSNull()]
        }
        guard let tabID = resolveTabID(json) else { return ["ok": false, "error": "tab not found"] }
        let newState = apply(
            event: event, tabID: tabID,
            agent: (json["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "claude",
            message: Self.nonEmpty(json["message"]), tool: Self.nonEmpty(json["tool"]),
            sessionID: Self.nonEmpty(json["session_id"]), cwd: Self.nonEmpty(json["cwd"]))
        if newState != nil { signalAttention(tabID: tabID) }
        return ["ok": true, "state": items[tabID]?.state.rawValue ?? NSNull()]
    }

    /// The orchestrator's tab when the event names its tab or pane.
    private func orchestratorTab(_ json: [String: Any]) -> UUID? {
        guard let tabID = orchestratorTabID() else { return nil }
        if (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) == tabID { return tabID }
        if let paneID = orchestratorPaneID(),
            (json["pane_id"] as? String).flatMap(UUID.init(uuidString:)) == paneID
        {
            return tabID
        }
        return nil
    }

    private func resolveTabID(_ json: [String: Any]) -> UUID? {
        if let id = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)), locate(id) != nil {
            return id
        }
        guard let paneID = (json["pane_id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        for controller in WindowManager.shared.controllers {
            if let pane = controller.appState.workspaceContainingPane(paneID)?.pane(for: paneID) {
                return pane.activeTab?.id
            }
        }
        return nil
    }

    /// Tab dot and desktop notification, skipped when the tab is in front.
    private func signalAttention(tabID: UUID) {
        guard let location = locate(tabID) else { return }
        if location.controller.isTabFocused(
            workspace: location.workspace, pane: location.pane, tabIndex: location.tabIndex)
        {
            markSeen(tabID: tabID)
            return
        }
        guard let item = items[tabID] else { return }
        location.controller.signalAgentAttention(
            workspace: location.workspace, pane: location.pane, tabIndex: location.tabIndex,
            body: Self.summary(of: item))
    }

    /// One line for menus and notifications: "Claude needs your permission to use Bash".
    /// `short` drops the agent's own message (status bar).
    static func summary(of item: Item, short: Bool = false) -> String {
        let name = displayName(of: item.agent)
        if !short, let message = item.message {
            return message.hasPrefix(name) ? message : "\(name): \(message)"
        }
        switch item.state {
        case .working: return item.tool.map { "\(name) is working (\($0))" } ?? "\(name) is working"
        case .needsInput: return "\(name) needs your input"
        case .done: return "\(name) is done"
        case .error: return "\(name) stopped with an error"
        }
    }

    static func displayName(of agent: String) -> String {
        AgentKind.infer(processName: agent, metadata: ["agent_kind": agent])?.shortName ?? agent.capitalized
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

extension AgentInbox {
    /// App-wide agent commands; nil when `cmd` is not one of them.
    /// `agent_inbox` lists items, `agent_jump` focuses `tab_id` (or the next one waiting).
    /// `agent_timeline` replies asynchronously: see `timeline(_:reply:)`.
    func handleSocketCommand(cmd: String, json: [String: Any]) -> [String: Any]? {
        switch cmd {
        case "agent_event":
            return handleSocketEvent(json)
        case "agent_inbox":
            prune()
            return ["ok": true, "attention": attentionCount, "items": sortedItems.map(Self.serialize)]
        case "agent_respond":
            return respond(json)
        case "agent_jump":
            if let id = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) {
                return ["ok": jump(to: id)]
            }
            return ["ok": jumpToNextAttention()]
        default:
            return nil
        }
    }

    private static func serialize(_ item: Item) -> [String: Any] {
        [
            "tab_id": item.tabID.uuidString,
            "agent": item.agent,
            "state": item.state.rawValue,
            "attention": item.needsAttention,
            "message": item.message ?? NSNull(),
            "tool": item.tool ?? NSNull(),
            "session_id": item.sessionID ?? NSNull(),
            "cwd": item.cwd ?? NSNull(),
            "updated_at": item.updatedAt.timeIntervalSince1970
        ]
    }
}
