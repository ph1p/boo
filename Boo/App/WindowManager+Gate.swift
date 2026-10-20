import Foundation

// MARK: - Capability gate for socket commands

extension WindowManager {
    /// Socket entry point: checks the caller's `BOO_TOKEN` before dispatching.
    func dispatchGated(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let caller = CapabilityTokens.shared.resolve(json["token"] as? String)
        let target = OrchestratorGate.needsTarget(cmd) ? gateTarget(cmd: cmd, json: json) : nil
        let decision = OrchestratorGate.decide(
            cmd: cmd, caller: caller, target: target,
            owns: { tab in caller.map { CapabilityTokens.shared.owns($0.tabID, tab) } ?? false },
            granted: { tab in caller.map { ApprovalCenter.shared.isGranted(caller: $0.tabID, tab: tab) } ?? false })
        switch decision {
        case .allow:
            dispatchCommand(cmd: cmd, json: json, reply: reply)
        case .reject(let error):
            reply(["ok": false, "error": error])
        case .approve:
            guard let caller else {
                reply(["ok": false, "error": "missing token"])
                return
            }
            // Pin the target so the card's command cannot drift to another pane later.
            var pinned = json
            if pinned["pane_id"] == nil, let paneID = resolvedPaneID(json) {
                pinned["pane_id"] = paneID.uuidString
            }
            let request = ApprovalCenter.shared.enqueue(
                cmd: cmd, json: pinned, caller: caller.tabID, targets: target?.tabIDs ?? []
            ) { [weak self] done in
                self?.dispatchCommand(cmd: cmd, json: pinned, reply: done)
            }
            reply(["ok": true, "status": "pending", "approval_id": request.id.uuidString])
        }
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
