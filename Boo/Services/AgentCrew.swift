import Foundation

extension Notification.Name {
    static let agentCrewChanged = Notification.Name("BooAgentCrewChanged")
}

/// Agents working together. Every agent tab gets a short handle (`t1`, `t2`, …)
/// that tools, the CLI and the user can type instead of a tab UUID. An agent
/// that starts another one (`new_agent_task`, `boo run`) becomes its parent:
/// when the helper finishes its turn, needs input or exits, Boo types a short
/// report into the parent's prompt, so nobody copies text between tabs.
///
/// Messages wait in an outbox while the receiving agent is busy or blocked on
/// a prompt, and go out together once it finishes its turn: typing into a
/// working agent would interrupt it, and typing into a permission prompt would
/// answer it. Tabs without a known agent never get typed into (a shell would
/// run the text); their messages are read with `agent_messages` (`boo inbox`).
@MainActor
final class AgentCrew {
    static let shared = AgentCrew()

    struct Link: Equatable {
        let parent: UUID
        var name: String
    }

    struct Message: Equatable, Sendable {
        let from: String
        let state: String?
        let text: String
        /// The sending tab, when it is one.
        var fromTab: UUID? = nil
    }

    enum Delivery: String {
        case delivered, queued
    }

    private(set) var handles: [UUID: Int] = [:]
    private var nextHandle = 1
    /// Child tab → the tab that started it.
    private(set) var links: [UUID: Link] = [:]
    /// Messages for a tab that could not take them yet.
    private(set) var outbox: [UUID: [Message]] = [:]
    private var lastStates: [UUID: AgentInbox.State] = [:]
    private var observer: NSObjectProtocol?
    private var flushScheduled = false
    /// When each agent-to-agent message was sent, per sender and receiver.
    private var sentAt: [String: [Date]] = [:]

    // Injected for tests.
    var state: (UUID) -> AgentInbox.State? = { AgentInbox.shared.items[$0]?.state }
    var title: (UUID) -> String? = { id in
        AgentInbox.locateInWindows(id).map { $0.pane.tabs[$0.tabIndex].title }
    }
    /// The name of the task workspace a tab runs in, which the user gave it or
    /// Boo made from its prompt. Wins over the tab title, which the agent rewrites.
    var taskName: (UUID) -> String? = { id in
        AgentInbox.locateInWindows(id).flatMap {
            AgentWorktree.looksLikeWorktree($0.workspace.folderPath) ? $0.workspace.customName : nil
        }
    }
    var isOrchestrator: (UUID) -> Bool = { $0 == OrchestratorController.shared.tabID }
    /// Whether the tab runs a coding agent that reads typed messages; a script
    /// that reports its state with `boo status` gets them from `boo inbox`.
    var acceptsTyping: (UUID) -> Bool = { tabID in
        AgentInbox.shared.items[tabID].flatMap { AgentKind(ipcName: $0.agent) } != nil
    }
    /// Pastes and submits text in a tab's terminal; false when it is not open.
    var deliver: (UUID, String) -> Bool = { AgentInbox.shared.sendMessage($0, $1) }
    /// Called after a delivery, so the receiver shows as working right away.
    var didDeliver: (UUID) -> Void = { tabID in
        guard let item = AgentInbox.shared.items[tabID] else { return }
        AgentInbox.shared.apply(event: "working", tabID: tabID, agent: item.agent)
    }
    /// The parent took this helper's answer, so the user doesn't owe it a look.
    var markSeen: (UUID) -> Void = { AgentInbox.shared.markSeen(tabID: $0) }
    /// Messages for the orchestrator go to its event stream instead of its prompt.
    var postEvent: (String, [String: Any]) -> Void = { OrchestratorEvents.shared.post($0, $1) }
    var now: () -> Date = { Date() }
    /// Closes a helper's tab without asking, when the tab that started it closed.
    var closeTab: (UUID) -> Void = { tabID in
        AgentInbox.locateInWindows(tabID)?.controller.closeHelperTab(tabID)
    }
    /// Runs a flush after the current inbox update; immediate in tests.
    var schedule: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    init() {}

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .agentInboxChanged, object: nil, queue: .main) {
            [weak self] notification in
            guard let inbox = notification.object as? AgentInbox else { return }
            MainActor.assumeIsolated { self?.inboxChanged(inbox.items) }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .agentCrewChanged, object: self)
    }

    // MARK: - Handles

    /// `t3`; issued on first use and never reused in this app session.
    @discardableResult
    func handle(for tabID: UUID) -> String {
        if let number = handles[tabID] { return "t\(number)" }
        handles[tabID] = nextHandle
        nextHandle += 1
        return "t\(nextHandle - 1)"
    }

    /// `t3 fix-tests`: handle plus task name (or tab title).
    func label(for tabID: UUID) -> String {
        let handle = handle(for: tabID)
        let label = name(for: tabID)
        return label.isEmpty ? handle : "\(handle) \(label)"
    }

    /// A tab from `parent`, `t3`, `3` or a tab UUID; `caller` resolves `parent`.
    func resolve(_ reference: String, caller: UUID?) -> UUID? {
        let ref = reference.trimmingCharacters(in: .whitespaces).lowercased()
        if ref == "parent" { return caller.flatMap { links[$0]?.parent } }
        if let id = UUID(uuidString: reference) { return id }
        let digits = ref.hasPrefix("t") ? String(ref.dropFirst()) : ref
        guard let number = Int(digits) else { return nil }
        return handles.first { $0.value == number }?.key
    }

    // MARK: - Links

    func link(child: UUID, parent: UUID, name: String) {
        handle(for: parent)
        handle(for: child)
        links[child] = Link(parent: parent, name: name)
        changed()
    }

    func children(of parent: UUID) -> [UUID] {
        links.filter { $0.value.parent == parent }.map(\.key).sorted { (handles[$0] ?? 0) < (handles[$1] ?? 0) }
    }

    /// A tab title without the status glyphs agents put in front of it
    /// (Claude's `✳`, spinner frames), so names read the same in every state.
    nonisolated static func displayName(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber })
    }

    /// A helper's name from its prompt: the first line, cut at a word.
    nonisolated static func shortName(_ prompt: String, limit: Int = 40) -> String {
        var line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // The first sentence names the job; the rest is how to do it.
        // `calc.py` and `add()` keep their dots: a sentence ends at ". ".
        if let end = line.range(of: ". ") { line = String(line[..<end.lowerBound]) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(limit)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// What the crew calls a tab: the name it was started with, its task
    /// workspace's name, else its title without status glyphs. A plain shell
    /// (someone running `boo send`) is "shell": its title is the last command.
    func name(for tabID: UUID) -> String {
        if let name = links[tabID]?.name ?? taskName(tabID) { return name }
        if state(tabID) == nil { return title(tabID) == nil ? "" : "shell" }
        return title(tabID).map(Self.displayName) ?? ""
    }

    /// Crew columns for `agent_inbox` rows.
    func fields(for tabID: UUID) -> [String: Any] {
        var fields: [String: Any] = [
            "handle": handle(for: tabID),
            "name": name(for: tabID),
            "children": children(of: tabID).map { handle(for: $0) },
            "queued": outbox[tabID]?.count ?? 0
        ]
        fields["parent"] = links[tabID].map { handle(for: $0.parent) } ?? NSNull()
        return fields
    }

    // MARK: - Messages

    /// The text typed into the receiver's prompt.
    nonisolated static func envelope(_ messages: [Message]) -> String {
        messages.map { message in
            let state = message.state.map { " state=\"\($0)\"" } ?? ""
            return "<boo from=\"\(message.from)\"\(state)>\n\(message.text)\n</boo>"
        }.joined(separator: "\n\n")
    }

    /// Sends `text` to `to`, now if it can take it, else when it next finishes a turn.
    @discardableResult
    func send(to: UUID, from: UUID?, text: String, state: String? = nil) -> Delivery {
        let message = Message(from: from.map(label(for:)) ?? "user", state: state, text: text, fromTab: from)
        if isOrchestrator(to) {
            postEvent(
                "agent_message",
                ["to": to.uuidString, "from": message.from, "state": state ?? NSNull(), "text": text])
            return .delivered
        }
        outbox[to, default: []].append(message)
        changed()
        return flush(to) ? .delivered : .queued
    }

    /// Hands queued messages to `tabID` when its agent waits at its prompt.
    @discardableResult
    private func flush(_ tabID: UUID) -> Bool {
        guard let messages = outbox[tabID], !messages.isEmpty else { return false }
        guard let state = state(tabID), state == .done || state == .error, acceptsTyping(tabID) else { return false }
        guard deliver(tabID, Self.envelope(messages)) else { return false }
        outbox[tabID] = nil
        for message in messages where message.state != nil { message.fromTab.map(markSeen) }
        didDeliver(tabID)
        changed()
        return true
    }

    /// Drops the reports from `child` that wait for `caller`: `boo wait` already
    /// handed it that answer, and typing it in again costs the caller a turn.
    /// Messages the child sent on purpose stay.
    @discardableResult
    func collected(from child: UUID, by caller: UUID) -> Int {
        guard let messages = outbox[caller] else { return 0 }
        let kept = messages.filter { $0.fromTab != child || $0.state == nil }
        guard kept.count < messages.count else { return 0 }
        outbox[caller] = kept.isEmpty ? nil : kept
        changed()
        return messages.count - kept.count
    }

    /// Reads and clears messages that wait for `tabID` (for tabs without an agent).
    func takeMessages(for tabID: UUID) -> [Message] {
        let messages = outbox.removeValue(forKey: tabID) ?? []
        if !messages.isEmpty { changed() }
        return messages
    }

    // MARK: - Reports

    /// Reports helpers' state changes to their parents and flushes outboxes of
    /// agents that just finished a turn.
    func inboxChanged(_ items: [UUID: AgentInbox.Item]) {
        for tabID in items.keys where handles[tabID] == nil { handle(for: tabID) }
        var ready: [UUID] = []
        for (tabID, item) in items.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            let previous = lastStates[tabID]
            guard previous != item.state else { continue }
            if item.state == .done || item.state == .error, outbox[tabID]?.isEmpty == false { ready.append(tabID) }
            guard let link = links[tabID] else { continue }
            switch item.state {
            // First seen idle: the session just started (`start` event), no turn to report.
            case .done where previous == nil && item.reply == nil && item.message == nil:
                break
            case .done:
                report(link, from: tabID, state: "done", text: item.reply ?? item.message ?? "Finished its turn.")
            case .needsInput:
                let ask = item.message ?? "Waiting for input."
                report(
                    link, from: tabID, state: "needs-input",
                    text: "\(ask)\nAnswer with send_message to \(handle(for: tabID)), or ask the user.")
            case .error:
                report(link, from: tabID, state: "error", text: item.message ?? "Stopped with an error.")
            case .working:
                break
            }
        }
        for tabID in lastStates.keys where items[tabID] == nil { ended(tabID) }
        lastStates = items.mapValues(\.state)
        guard !ready.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        // After this inbox update: a delivery marks the receiver working, which updates the inbox again.
        schedule { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            for tabID in self.outbox.keys { self.flush(tabID) }
        }
    }

    private func report(_ link: Link, from child: UUID, state: String, text: String) {
        send(to: link.parent, from: child, text: Self.trimmed(text), state: state)
    }

    /// An agent quit or its tab closed.
    private func ended(_ tabID: UUID) {
        if let link = links[tabID], title(tabID) != nil || state(link.parent) != nil {
            report(link, from: tabID, state: "exited", text: "The agent exited.")
        }
        if title(tabID) == nil { tabClosed(tabID) }
    }

    /// A tab closed: its helpers close with it. Their worktrees and branches
    /// stay, so Review, Merge and Discard still work on them.
    func tabClosed(_ tabID: UUID) {
        let helpers = children(of: tabID)
        forget(tabID)
        for helper in helpers where title(helper) != nil { closeTab(helper) }
    }

    /// Drops a closed tab: its links, its children's links to it and its outbox.
    func forget(_ tabID: UUID) {
        links[tabID] = nil
        for child in children(of: tabID) { links[child] = nil }
        outbox[tabID] = nil
        sentAt = sentAt.filter { !$0.key.contains(tabID.uuidString) }
        handles[tabID] = nil
        lastStates[tabID] = nil
        changed()
    }

    static let maxReportLength = 4000
    /// Two agents may message each other this often per `messageWindow`;
    /// more looks like a loop and needs the user.
    static let maxMessages = 8
    static let messageWindow: TimeInterval = 600

    /// Records a message from `from` to `to`; false when that pair is over the limit.
    private func allowMessage(from: UUID, to: UUID) -> Bool {
        let key = [from.uuidString, to.uuidString].sorted().joined(separator: "|")
        let cutoff = now().addingTimeInterval(-Self.messageWindow)
        var times = (sentAt[key] ?? []).filter { $0 > cutoff }
        guard times.count < Self.maxMessages else {
            sentAt[key] = times
            return false
        }
        times.append(now())
        sentAt[key] = times
        return true
    }

    static func trimmed(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxReportLength else { return text }
        return String(text.prefix(maxReportLength)) + "\n… (truncated; read_pane shows the rest)"
    }

    // MARK: - Socket

    /// `agent_send {tab_id, text}`, `agent_messages` and `agent_collected {tab_id}`;
    /// nil for other commands.
    /// `tab_id` may be a handle or `parent` (resolved in `WindowManager.dispatchGated`).
    func handleSocketCommand(cmd: String, json: [String: Any], caller: UUID?) -> [String: Any]? {
        switch cmd {
        case "agent_send":
            guard let to = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return ["ok": false, "error": "missing tab_id (a handle like t3, parent, or a tab UUID)"]
            }
            guard to != caller else { return ["ok": false, "error": "that is your own tab"] }
            guard title(to) != nil else { return ["ok": false, "error": "no open tab \(json["to"] ?? to.uuidString)"] }
            guard let text = json["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return ["ok": false, "error": "text is empty"] }
            if let caller, !allowMessage(from: caller, to: to) {
                return [
                    "ok": false,
                    "error":
                        "\(Self.maxMessages) messages between you and \(label(for: to)) in \(Int(Self.messageWindow / 60)) minutes; this looks like a loop. Stop and ask the user."
                ]
            }
            let delivery = send(to: to, from: caller, text: text)
            return ["ok": true, "status": delivery.rawValue, "to": label(for: to)]
        case "agent_collected":
            guard let caller, let child = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return ["ok": false, "error": "needs tab_id, inside a Boo terminal"]
            }
            markSeen(child)
            return ["ok": true, "dropped": collected(from: child, by: caller)]
        case "agent_messages":
            guard let caller else { return ["ok": false, "error": "run this inside a Boo terminal"] }
            let messages = takeMessages(for: caller).map { message -> [String: Any] in
                ["from": message.from, "state": message.state ?? NSNull(), "text": message.text]
            }
            return ["ok": true, "handle": handle(for: caller), "messages": messages]
        default:
            return nil
        }
    }
}
