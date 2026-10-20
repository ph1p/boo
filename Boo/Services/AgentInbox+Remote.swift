import AppKit
import CGhostty

/// Answering agents from the remote-control page: each waiting agent comes
/// with the end of its screen, where the agent shows what it asks to do, and
/// can be approved (Return picks the agent's default "Yes") or denied (Escape)
/// without bringing its tab to the front on the Mac.
extension AgentInbox {
    enum Response: String {
        case approve, deny
    }

    /// Lines of the agent's screen sent along, enough for a permission dialog.
    static let previewLines = 18

    /// Agents waiting for the user, for `get_state` on the remote page.
    func remoteItems() -> [[String: Any]] {
        prune()
        return sortedItems.filter(\.needsAttention).map { item in
            var entry: [String: Any] = [
                "tab_id": item.tabID.uuidString,
                "agent": item.agent,
                "label": AgentHandoff.label(for: item, inbox: self),
                "state": item.state.rawValue,
                "summary": Self.summary(of: item),
                "updated_at": item.updatedAt.timeIntervalSince1970
            ]
            if item.state == .needsInput, let screen = readScreen(item.tabID) {
                entry["preview"] = Self.preview(of: screen)
            }
            return entry
        }
    }

    /// `agent_respond {text}`: a message for the agent in any state, pasted and
    /// submitted like typed input. Not for permission prompts, where Return and
    /// Escape are the answers.
    private func message(_ tabID: UUID, _ text: String) -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["ok": false, "error": "text is empty"]
        }
        guard let item = items[tabID] else { return ["ok": false, "error": "no agent runs in that tab"] }
        if item.state == .needsInput {
            return ["ok": false, "error": "the agent is waiting for approve or deny, not a message"]
        }
        guard sendMessage(tabID, text) else { return ["ok": false, "error": "the agent's terminal is not open"] }
        _ = apply(event: "working", tabID: tabID, agent: item.agent)
        return ["ok": true]
    }

    /// Last `lines` non-trailing-blank lines of a screen, trailing spaces trimmed.
    static func preview(of screen: String, lines: Int = previewLines) -> String {
        var rows = screen.components(separatedBy: "\n").map { row in
            var row = Substring(row)
            while row.last == " " { row.removeLast() }
            return String(row)
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    /// `agent_respond`: `tab_id`, `response` (`approve` or `deny`) and the
    /// `updated_at` the page showed, so an answer never lands on a newer prompt;
    /// or `tab_id` and `text`, a message for the agent.
    func respond(_ json: [String: Any]) -> [String: Any] {
        guard let tabID = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return ["ok": false, "error": "missing tab_id"]
        }
        if json["response"] == nil, let text = json["text"] as? String {
            return message(tabID, text)
        }
        guard let response = (json["response"] as? String).flatMap(Response.init(rawValue:)) else {
            return ["ok": false, "error": "response must be approve or deny"]
        }
        guard let item = items[tabID], item.state == .needsInput else {
            return ["ok": false, "error": "the agent is not waiting for an answer"]
        }
        if let shown = json["updated_at"] as? Double, abs(shown - item.updatedAt.timeIntervalSince1970) > 0.001 {
            return ["ok": false, "error": "the agent asked something new, look again"]
        }
        guard sendResponse(tabID, response) else {
            return ["ok": false, "error": "the agent's terminal is not open"]
        }
        // The agent's hooks report the next state; until then, show the answer.
        switch response {
        case .approve:
            _ = apply(event: "working", tabID: tabID, agent: item.agent)
        case .deny:
            // Claude waits for new instructions after a denial, without a Stop hook.
            _ = apply(event: "done", tabID: tabID, agent: item.agent, message: "Denied from remote control")
            markSeen(tabID: tabID)
        }
        return ["ok": true]
    }

    /// The terminal of an agent's tab, open in some window (displayed or not).
    static func terminalView(ofTab tabID: UUID) -> GhosttyView? {
        guard let location = locateInWindows(tabID) else { return nil }
        return location.controller.workspacePaneViews[location.workspace.id]?[location.pane.id]?
            .terminalView(forTab: tabID)
    }

    static func sendResponse(_ response: Response, to view: GhosttyView) {
        switch response {
        case .approve: view.sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r")
        case .deny: view.sendKey(keyCode: 0x35, mods: GHOSTTY_MODS_NONE, text: "\u{1b}")
        }
    }
}
