import Foundation

// MARK: - Capability gate for socket commands

extension WindowManager {
    /// Socket entry point: checks the caller's `BOO_TOKEN` before dispatching.
    func dispatchGated(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let caller = CapabilityTokens.shared.resolve(json["token"] as? String)
        if OrchestratorGate.browserCommands.contains(cmd) {
            dispatchBrowser(cmd: cmd, json: json, caller: caller, reply: reply)
            return
        }
        // Handles (`t3`) and `parent` become tab UUIDs before the gate looks at the target.
        var json = json
        if cmd == "agent_send", json["tab_id"] == nil, let to = json["to"] { json["tab_id"] = to }
        if let reference = json["tab_id"] as? String, UUID(uuidString: reference) == nil {
            guard let tabID = AgentCrew.shared.resolve(reference, caller: callerTab(caller, json)) else {
                reply(["ok": false, "error": "no agent \(reference) (list_agents shows handles)"])
                return
            }
            json["tab_id"] = tabID.uuidString
        }
        let target = OrchestratorGate.needsTarget(cmd) ? gateTarget(cmd: cmd, json: json) : nil
        let decision = OrchestratorGate.decide(
            cmd: cmd, caller: caller, target: target,
            owns: { tab in caller.map { CapabilityTokens.shared.owns($0.tabID, tab) } ?? false },
            granted: { tab in caller.map { ApprovalCenter.shared.isGranted(caller: $0.tabID, tab: tab) } ?? false })
        switch decision {
        case .allow:
            if let caller, caller.grade == .gated, let target, target.isAgent,
                OrchestratorLoopGuard.writeCommands.contains(cmd),
                OrchestratorLoopGuard.shared.record(target.tabIDs)
            {
                enqueueCard(cmd: cmd, json: json, caller: caller, target: target, loop: true, reply: reply)
            } else {
                dispatchCommand(cmd: cmd, json: json, reply: reply)
            }
        case .reject(let error):
            reply(["ok": false, "error": error])
        case .approve:
            guard let caller else {
                reply(["ok": false, "error": "missing token"])
                return
            }
            enqueueCard(cmd: cmd, json: json, caller: caller, target: target, loop: false, reply: reply)
        }
    }

    /// `boo browser`: resolves the tab (id, id prefix, or the caller's last
    /// one) and asks the user before touching a tab the caller did not open.
    private func dispatchBrowser(
        cmd: String, json: [String: Any], caller: CapabilityTokens.Caller?,
        reply: @escaping ([String: Any]) -> Void
    ) {
        var json = json
        let reference = json["tab_id"] as? String
        let tab = AgentBrowser.shared.tab(matching: reference, caller: caller?.tabID)
        if let reference, !reference.isEmpty, tab == nil {
            reply(["ok": false, "error": "no browser tab \(reference) (boo browser ls lists them)"])
            return
        }
        if let tab { json["tab_id"] = tab.uuidString }
        let decision = OrchestratorGate.decideBrowser(
            cmd: cmd, caller: caller, tab: tab, enabled: AppSettings.shared.agentBrowserAccessEnabled,
            owns: { tab in caller.map { CapabilityTokens.shared.owns($0.tabID, tab) } ?? false },
            granted: { tab in caller.map { ApprovalCenter.shared.isGranted(caller: $0.tabID, tab: tab) } ?? false })
        switch decision {
        case .allow:
            dispatchCommand(cmd: cmd, json: json, reply: reply)
        case .reject(let error):
            reply(["ok": false, "error": error])
        case .approve:
            guard let caller, let tab else { return reply(["ok": false, "error": "missing token"]) }
            let target = OrchestratorGate.Target(tabIDs: [tab], isAgent: false, isRemote: false)
            enqueueCard(cmd: cmd, json: json, caller: caller, target: target, loop: false, reply: reply)
        }
    }

    /// Holds the command on an approval card and replies `pending` at once.
    private func enqueueCard(
        cmd: String, json: [String: Any], caller: CapabilityTokens.Caller, target: OrchestratorGate.Target?,
        loop: Bool, reply: @escaping ([String: Any]) -> Void
    ) {
        // Pin the target so the card's command cannot drift to another pane later.
        var pinned = json
        if pinned["pane_id"] == nil, let paneID = resolvedPaneID(json) {
            pinned["pane_id"] = paneID.uuidString
        }
        let targets = target?.tabIDs ?? []
        let request = ApprovalCenter.shared.enqueue(
            cmd: cmd, json: pinned, caller: caller.tabID, targets: targets, loop: loop
        ) { [weak self] done in
            if loop { targets.forEach(OrchestratorLoopGuard.shared.reset) }
            self?.dispatchCommand(cmd: cmd, json: pinned, reply: done)
        }
        var pending: [String: Any] = ["ok": true, "status": "pending", "approval_id": request.id.uuidString]
        if loop { pending["reason"] = "possible_loop" }
        reply(pending)
    }

    /// The tabs a sensitive command acts on, nil when its id resolves nowhere.
    func gateTarget(cmd: String, json: [String: Any]) -> OrchestratorGate.Target? {
        let tabs: [Pane.Tab]
        if OrchestratorGate.tabCommands.contains(cmd) {
            guard let id = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)),
                let location = AgentInbox.locateInWindows(id)
            else { return nil }
            tabs = [location.pane.tabs[location.tabIndex]]
        } else {
            guard let pane = resolvedPane(json) else { return nil }
            if OrchestratorGate.closeCommands.contains(cmd) {
                tabs = pane.tabs
            } else {
                guard let tab = pane.activeTab else { return nil }
                tabs = [tab]
            }
        }
        let inbox = AgentInbox.shared
        return OrchestratorGate.Target(
            tabIDs: tabs.map(\.id),
            isAgent: tabs.contains { inbox.items[$0.id] != nil },
            isRemote: tabs.contains { $0.remoteSession != nil })
    }

    /// The tab a command comes from: its token's, else the active tab of its pane.
    func callerTab(_ caller: CapabilityTokens.Caller?, _ json: [String: Any]) -> UUID? {
        caller?.tabID ?? resolvedPane(json)?.activeTab?.id
    }

    /// The pane named by `pane_id`, else the active pane of the active window
    /// (where pane commands without an id land).
    private func resolvedPane(_ json: [String: Any]) -> Pane? {
        guard let paneID = resolvedPaneID(json) else { return nil }
        let owner = controller(owningPane: paneID) ?? activeController
        return owner?.appState.workspaceContainingPane(paneID)?.pane(for: paneID)
    }

    private func resolvedPaneID(_ json: [String: Any]) -> UUID? {
        if let id = json["pane_id"] as? String { return UUID(uuidString: id) }
        return activeController?.activeWorkspace?.activePaneID
    }
}
