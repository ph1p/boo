import Cocoa

extension Notification.Name {
    static let agentInboxChanged = Notification.Name("BooAgentInboxChanged")
}

/// App-wide list of coding agents and what each one is waiting for, fed by
/// agent hooks over the socket (`agent_event`). Spans every window, so one
/// place shows which agent needs an answer and jumps to its tab.
@MainActor
final class AgentInbox {
    static let shared: AgentInbox = {
        let inbox = AgentInbox()
        inbox.watchesLiveness = true
        return inbox
    }()

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
        /// The agent's last answer when it finished a turn (from its Stop hook);
        /// what a helper reports back to the agent that started it.
        var reply: String?
        var sessionID: String?
        var cwd: String?
        var updatedAt: Date
        /// The user looked at the tab since the agent stopped.
        var seen: Bool
        /// Waits on a question (`AskUserQuestion`), not a permission prompt:
        /// Return would pick its first option, so it is answered in its tab.
        var asksQuestion = false
        /// Listed by SessionStart and no turn yet: a new helper still reading
        /// its prompt, not one that finished.
        var fresh = false
        /// The tab's foreground process when the agent last reported: the agent
        /// itself. Tells a nested or new agent apart, and whether it still runs.
        var pid: pid_t?
        /// When the agent's hook last sent a report; an older one that arrives
        /// late is dropped. Boo's own updates (a delivery, a title read) carry no
        /// stamp, so a slow hook still overrules them.
        var reportedAt: Date?
        /// Subagents (the Agent tool) started and not yet stopped. A background
        /// one outlives the turn that started it. Starts and stops toggle an
        /// id, so a stop that arrives before its start (hooks run as separate
        /// processes) cancels out.
        var subagents: Set<String> = []
        /// When the agent ended its turn while background work it started
        /// still ran: listed as working until that work ends (see
        /// "Background work" below).
        var heldSince: Date?
        /// Whether the agent is held for its background work.
        var holdsForBackground: Bool { heldSince != nil }
        /// When a held agent's background work was first seen gone.
        var backgroundEndedAt: Date?
        /// Background shells already waited out for `backgroundLimit` (watchers
        /// that never exit): they hold no later turn.
        var waitedOutShells: Set<pid_t> = []
        /// When a subagent last started, stopped or used a tool. An interrupt
        /// sends no SubagentStop, so a subagent quiet for `subagentQuiet` no
        /// longer holds the agent.
        var subagentActivityAt: Date?

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

    /// The process in the foreground of a tab's terminal; nil when not open.
    var foregroundPID: (UUID) -> pid_t? = { AgentInbox.terminalView(ofTab: $0)?.foregroundPID }
    var isAlive: (pid_t) -> Bool = ProcessTree.isAlive
    /// Background commands the agent with this PID still runs (dev servers left out).
    var backgroundShells: (pid_t) -> Set<pid_t> = ProcessTree.claudeBackgroundShells(of:)
    /// Polls held agents until their background work ends; nil while none is held.
    var backgroundTimer: Timer?
    /// Sweeps out agents whose tab closed or whose process exited; only the
    /// app's shared inbox runs it (tests call `sweep()` themselves).
    var watchesLiveness = false
    var livenessTimer: Timer?

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

    /// Whether an agent still runs in its tab, by the process it reported from.
    enum Presence {
        /// In the foreground of its terminal, or not known: it reads typed text.
        case foreground
        /// Alive but not in the foreground (suspended, or a program it started).
        case background
        /// Its process exited without a SessionEnd.
        case gone
    }

    func presence(of tabID: UUID) -> Presence {
        guard let pid = items[tabID]?.pid, let current = foregroundPID(tabID), current != pid else {
            return .foreground
        }
        return isAlive(pid) ? .background : .gone
    }

    /// Every status bar redraws from this.
    private func changed() {
        if watchesLiveness { items.isEmpty ? stopLivenessWatch() : startLivenessWatch() }
        NotificationCenter.default.post(name: .agentInboxChanged, object: self)
    }

    // MARK: - Events

    /// Applies one hook event. Returns the item's new state when the agent now
    /// waits for the user (so the caller can notify), nil otherwise.
    @discardableResult
    func apply(
        event: String, tabID: UUID, agent: String = "claude", message: String? = nil,
        tool: String? = nil, reply: String? = nil, sessionID: String? = nil, cwd: String? = nil,
        pid: pid_t? = nil, reportedAt: Date? = nil, subagentID: String? = nil, now: Date = Date()
    ) -> State? {
        // Subagent starts and stops only count; they arrive in any order.
        if event == "subagent-start" || event == "subagent-stop" {
            trackSubagent(id: subagentID, tabID: tabID, now: now)
            return nil
        }
        if subagentID != nil { items[tabID]?.subagentActivityAt = now }
        if let existing = items[tabID] {
            // Hooks run as separate processes and can arrive out of order.
            if let reportedAt, let last = existing.reportedAt, reportedAt < last { return nil }
            if Self.isNestedSession(existing, event: event, sessionID: sessionID, pid: pid, now: now) { return nil }
            // A failed turn can still report its end (OpenCode idles after
            // session.error); the error stays until the next prompt.
            if existing.state == .error, event == "stop" || event == "done" { return nil }
            // A background subagent's tools run after the turn ended; the agent
            // stays held until that work ends.
            if existing.holdsForBackground, subagentID != nil, event == "tool" { return nil }
        }
        if event == "end" {
            remove(tabID: tabID)
            return nil
        }
        if event == "start" {
            // A new or resumed session idles at its prompt: list it (with a handle)
            // before its first turn, so a resumed task leaves Stopped at once.
            // A known agent's /clear or compaction keeps its row; another process
            // with a new session replaces the row of one that quit unreported.
            if let existing = items[tabID], !Self.isOtherAgent(existing, sessionID: sessionID, pid: pid) { return nil }
            var item = Item(tabID: tabID, agent: agent, state: .done, updatedAt: now, seen: true)
            item.sessionID = sessionID
            item.pid = pid
            item.reportedAt = reportedAt
            item.cwd = cwd
            item.fresh = true
            items[tabID] = item
            changed()
            return nil
        }
        if event == "stop", agent == "claude",
            holdForBackground(
                tabID: tabID, reply: reply, sessionID: sessionID, cwd: cwd, pid: pid, reportedAt: reportedAt, now: now)
        {
            return nil
        }
        let previous = items[tabID]?.state
        guard
            var item = Self.updated(
                items[tabID], event: event, tabID: tabID, agent: agent, message: message, tool: tool,
                reply: reply, sessionID: sessionID, cwd: cwd, now: now)
        else { return nil }
        item.pid = pid ?? item.pid
        item.reportedAt = reportedAt ?? item.reportedAt
        items[tabID] = item
        changed()
        return item.needsAttention && item.state != previous ? item.state : nil
    }

    /// How long a working agent's session holds its tab against another session's
    /// events; after that the other session is taken as a new agent in the tab
    /// (the first one quit without a SessionEnd).
    static let nestedSessionWindow: TimeInterval = 30 * 60

    /// An event from another session than the tab's agent, sent while that agent
    /// works: a `claude -p` it runs in a tool inherits the tab's `BOO_TAB_ID`.
    /// It must not end the agent's row or change its state. A different session
    /// after the agent's turn is a new agent in the tab (`/clear`, a restart);
    /// the agent's own SessionEnd, not another's, ends its row.
    /// A nested `claude -p` shares the agent's process group, so another
    /// foreground process is a new agent, not a nested one.
    static func isNestedSession(
        _ existing: Item, event: String, sessionID: String?, pid: pid_t?, now: Date
    ) -> Bool {
        guard let own = existing.sessionID, let sessionID, sessionID != own else { return false }
        if isOtherAgent(existing, sessionID: sessionID, pid: pid) { return false }
        if event == "end" { return true }
        return existing.state == .working && now.timeIntervalSince(existing.updatedAt) < nestedSessionWindow
    }

    /// Another session in another process than the tab's agent: a new agent.
    static func isOtherAgent(_ existing: Item, sessionID: String?, pid: pid_t?) -> Bool {
        guard let sessionID, sessionID != existing.sessionID, let pid, let known = existing.pid else { return false }
        return pid != known
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
                    reply: nil, sessionID: sessionID, cwd: cwd, now: now)
            else { return }
            orchestrator = item
        }
        changed()
    }

    /// `existing` after one hook event; nil for events that change nothing.
    private static func updated(
        _ existing: Item?, event: String, tabID: UUID, agent: String, message: String?,
        tool: String?, reply: String?, sessionID: String?, cwd: String?, now: Date
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
        item.fresh = false
        item.updatedAt = now
        item.heldSince = nil
        item.backgroundEndedAt = nil
        item.sessionID = sessionID ?? item.sessionID
        item.cwd = cwd ?? item.cwd
        switch state {
        case .working:
            item.tool = tool ?? item.tool
            item.message = nil
        case .needsInput, .done, .error:
            // Claude's generic "needs your permission" notice follows a question;
            // keep the question it is about.
            let followsQuestion = previous == .needsInput && event == "permission" && item.message != nil
            if !followsQuestion { item.message = message }
            if state == .error { item.message = message.map { "Stopped: \($0)" } }
            item.asksQuestion = event == "question" || (followsQuestion && item.asksQuestion)
            if state != previous { item.seen = false }
        }
        // Codex reports a turn end twice (notify and its Stop hook); the second
        // may carry no reply.
        if state == .done { item.reply = reply ?? (previous == .done ? item.reply : nil) }
        return item
    }

    /// The user is looking at `tabID`: done/error stop asking for attention.
    func markSeen(tabID: UUID) {
        guard var item = items[tabID], !item.seen else { return }
        item.seen = true
        items[tabID] = item
        changed()
    }

    /// The user interrupted the agent's turn (Esc), which sends no Stop: it is
    /// done and seen, without a notification. Its foreground subagents died
    /// with the turn and sent no SubagentStop either.
    func interrupted(tabID: UUID) {
        guard let item = items[tabID], item.state == .working else { return }
        items[tabID]?.subagents = []
        apply(event: "stop", tabID: tabID, agent: item.agent)
        markSeen(tabID: tabID)
    }

    /// Forgets every agent and the orchestrator: the agents switch went off.
    func clear() {
        guard !items.isEmpty || orchestrator != nil else { return }
        items = [:]
        orchestrator = nil
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

    /// How often the shared inbox looks for closed tabs and exited agents.
    static let livenessInterval: TimeInterval = 3

    /// Drops items whose tab closed (a close confirmed in a sheet, a closed
    /// workspace or window) or whose agent process exited without a SessionEnd
    /// (killed, crashed, its ssh dropped). Items with no known process, such as
    /// remote ones fed by the title, only go with their tab.
    func sweep() {
        let gone = items.values.filter { item in
            if locate(item.tabID) == nil { return true }
            guard let pid = item.pid else { return false }
            return !isAlive(pid)
        }.map(\.tabID)
        guard !gone.isEmpty else { return }
        for id in gone { items.removeValue(forKey: id) }
        changed()
    }

    private func startLivenessWatch() {
        guard livenessTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.livenessInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer.tolerance = 1
        livenessTimer = timer
    }

    private func stopLivenessWatch() {
        livenessTimer?.invalidate()
        livenessTimer = nil
    }

    // MARK: - Jumping

    /// Bring the tab's window forward and focus the tab.
    @discardableResult
    func jump(to tabID: UUID) -> Bool {
        guard let location = locate(tabID) else {
            remove(tabID: tabID)
            return false
        }
        Self.focus(location)
        markSeen(tabID: tabID)
        return true
    }

    /// Brings a located tab's window forward and selects the tab.
    static func focus(_ location: Location) {
        NSApp.activate(ignoringOtherApps: true)
        location.controller.window?.makeKeyAndOrderFront(nil)
        location.controller.focusActivity(
            workspaceID: location.workspace.id, paneID: location.pane.id, tabIndex: location.tabIndex)
    }

    /// The agent that finished its turn most recently, seen or not.
    @discardableResult
    func jumpToLastFinished() -> Bool {
        prune()
        let finished = items.values.filter { $0.state == .done || $0.state == .error }
        guard let last = finished.max(by: { $0.updatedAt < $1.updatedAt }) else { return false }
        return jump(to: last.tabID)
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
        // Agents off: hooks installed before the switch flipped report nothing.
        guard AppSettings.shared.agentsEnabled else { return ["ok": true, "state": NSNull()] }
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
            reply: Self.nonEmpty(json["reply"]),
            sessionID: Self.nonEmpty(json["session_id"]), cwd: Self.nonEmpty(json["cwd"]),
            pid: foregroundPID(tabID), reportedAt: (json["at"] as? Double).map(Date.init(timeIntervalSince1970:)),
            subagentID: Self.nonEmpty(json["subagent_id"]))
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
        if let id = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) {
            // A hook that names its tab is never moved to another one: when the
            // tab closed, the pane's active tab is a different agent (or none).
            return locate(id) != nil ? id : nil
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
    func signalAttention(tabID: UUID) {
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
            let crew = AgentCrew.shared
            let rows = sortedItems.map { Self.serialize($0).merging(crew.fields(for: $0.tabID)) { $1 } }
            return ["ok": true, "attention": attentionCount, "items": rows]
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
            "reply": item.reply ?? NSNull(),
            "tool": item.tool ?? NSNull(),
            "session_id": item.sessionID ?? NSNull(),
            "cwd": item.cwd ?? NSNull(),
            "fresh": item.fresh,
            "updated_at": item.updatedAt.timeIntervalSince1970
        ]
    }
}

// MARK: - Background work

/// Background work: Claude Code ends a turn (its Stop hook) while commands it
/// started with `run_in_background`, a Monitor or a background subagent still
/// run, and wakes up again when they finish. Such an agent is not done: it is
/// listed as working, with no attention ping, until that work ends.
extension AgentInbox {
    /// The tool label a held agent shows ("using background tasks").
    static let backgroundTool = "background tasks"
    /// How often held agents are checked for their background work.
    static let backgroundPollInterval: TimeInterval = 2
    /// After the background work ends, Claude starts a turn on its own; the
    /// agent stays working this long for that turn's first report.
    static let backgroundGrace: TimeInterval = 15
    /// The longest an agent is held: a watcher (`tsc --watch`, a test watcher)
    /// never exits, so after this the agent is done anyway.
    static let backgroundLimit: TimeInterval = 10 * 60
    /// A subagent with no start, stop or tool report for this long is taken
    /// as gone: an interrupted one never sends its SubagentStop. Its commands
    /// still count as background shells while they run.
    static let subagentQuiet: TimeInterval = 3 * 60

    /// Whether the agent's subagents still count as running at `now`.
    static func hasLiveSubagents(_ item: Item, now: Date) -> Bool {
        guard !item.subagents.isEmpty else { return false }
        guard let last = item.subagentActivityAt else { return true }
        return now.timeIntervalSince(last) < subagentQuiet
    }

    /// Whether the agent still has background work: subagents, or shells of
    /// its process.
    func hasBackgroundWork(_ item: Item, now: Date = Date()) -> Bool {
        if Self.hasLiveSubagents(item, now: now) { return true }
        guard let pid = item.pid else { return false }
        return !backgroundShells(pid).subtracting(item.waitedOutShells).isEmpty
    }

    /// Holds a Stop as working while background work runs. True when it did;
    /// the turn's reply is kept for when the agent is finally done.
    func holdForBackground(
        tabID: UUID, reply: String?, sessionID: String?, cwd: String?, pid: pid_t?, reportedAt: Date?, now: Date
    ) -> Bool {
        guard var item = items[tabID] else { return false }
        item.pid = pid ?? item.pid
        // Subagents gone quiet were interrupted: they hold no later turn.
        if !Self.hasLiveSubagents(item, now: now) {
            item.subagents = []
            items[tabID]?.subagents = []
        }
        guard hasBackgroundWork(item, now: now) else { return false }
        item.heldSince = item.heldSince ?? now
        item.state = .working
        item.backgroundEndedAt = nil
        item.tool = Self.backgroundTool
        item.message = nil
        item.asksQuestion = false
        item.fresh = false
        item.reply = reply ?? item.reply
        item.updatedAt = now
        item.sessionID = sessionID ?? item.sessionID
        item.cwd = cwd ?? item.cwd
        item.reportedAt = reportedAt ?? item.reportedAt
        items[tabID] = item
        changed()
        startBackgroundWatch()
        return true
    }

    /// Records a subagent's start or stop (SubagentStart / SubagentStop).
    func trackSubagent(id: String?, tabID: UUID, now: Date = Date()) {
        guard let id else { return }
        items[tabID]?.subagents.formSymmetricDifference([id])
        items[tabID]?.subagentActivityAt = now
    }

    /// Ends the hold of every agent whose background work is gone for
    /// `backgroundGrace` without a newer report, or that was held for
    /// `backgroundLimit`: it is done, with the reply of the turn it held.
    func checkBackground(now: Date = Date()) {
        for (tabID, item) in items where item.holdsForBackground {
            if let since = item.heldSince, now.timeIntervalSince(since) >= Self.backgroundLimit {
                // What still runs now is waited out: it holds no later turn.
                if let pid = item.pid { items[tabID]?.waitedOutShells.formUnion(backgroundShells(pid)) }
                items[tabID]?.subagents = []
                finishHold(tabID: tabID, item: item, now: now)
                continue
            }
            if hasBackgroundWork(item, now: now) {
                items[tabID]?.backgroundEndedAt = nil
                continue
            }
            guard let ended = item.backgroundEndedAt else {
                items[tabID]?.backgroundEndedAt = now
                continue
            }
            guard now.timeIntervalSince(ended) >= Self.backgroundGrace else { continue }
            finishHold(tabID: tabID, item: item, now: now)
        }
        if !items.values.contains(where: \.holdsForBackground) { stopBackgroundWatch() }
    }

    /// Ends a hold: the agent is done with the reply of the turn it held.
    private func finishHold(tabID: UUID, item: Item, now: Date) {
        items[tabID]?.heldSince = nil
        if apply(event: "stop", tabID: tabID, agent: item.agent, reply: item.reply, now: now) != nil {
            signalAttention(tabID: tabID)
        }
    }

    func startBackgroundWatch() {
        guard backgroundTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundPollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.checkBackground() }
        }
        timer.tolerance = 0.5
        backgroundTimer = timer
    }

    func stopBackgroundWatch() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }
}
