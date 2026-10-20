import Foundation

/// Socket commands that span windows, for the orchestrator: the whole app's
/// layout, any tab's screen, and agent tasks addressed by `tab_id`.
extension WindowManager {
    /// Handles `cmd` when it is one of these; false to let normal routing run.
    func dispatchAppWide(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) -> Bool {
        let tabID = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:))
        switch cmd {
        case "get_layout":
            let paneID = (json["pane_id"] as? String).flatMap(UUID.init(uuidString:))
            let fromOrchestrator = paneID.map(OrchestratorController.shared.isOrchestratorPane) ?? false
            guard json["scope"] as? String == "app" || fromOrchestrator else { return false }
            let caller = CapabilityTokens.shared.resolve(json["token"] as? String)?.tabID
            reply(appLayout(caller: caller))
            return true
        case "get_screen":
            guard let tabID else { return false }
            guard let terminal = AgentInbox.terminalView(ofTab: tabID) else {
                reply(["ok": false, "error": "no open terminal tab with that tab_id"])
                return true
            }
            let tab = AgentInbox.locateInWindows(tabID).map { $0.pane.tabs[$0.tabIndex] }
            let text =
                (json["lines"] as? Int).flatMap { terminal.readRecentText(lines: min($0, 5000)) }
                ?? terminal.readViewportText()
            reply([
                "ok": true, "tab_id": tabID.uuidString, "text": text ?? "",
                "title": tab?.title ?? "", "cwd": tab?.workingDirectory ?? ""
            ])
            return true
        case _ where MainWindowController.taskCommands.contains(cmd):
            guard let tabID else {
                reply(["ok": false, "error": "missing tab_id"])
                return true
            }
            guard let location = AgentInbox.locateInWindows(tabID) else {
                reply(["ok": false, "error": "no tab with that tab_id"])
                return true
            }
            location.controller.handleTaskCommand(
                cmd: cmd, workspace: location.workspace, tabID: tabID, json: json, reply: reply)
            return true
        default:
            return false
        }
    }

    /// Every window, workspace, pane and tab, with each agent's state. `owned`
    /// marks the agents `caller` started.
    func appLayout(caller: UUID?) -> [String: Any] {
        let inbox = AgentInbox.shared
        let windows: [[String: Any]] = controllers.map { controller in
            let workspaces: [[String: Any]] = controller.appState.workspaces.map { workspace in
                let panes: [[String: Any]] = workspace.splitTree.leafIDs.compactMap { paneID in
                    guard let pane = workspace.pane(for: paneID) else { return nil }
                    let tabs: [[String: Any]] = pane.tabs.enumerated().map { index, tab in
                        var info: [String: Any] = [
                            "id": tab.id.uuidString, "title": tab.title, "type": tab.contentType.rawValue,
                            "active": index == pane.activeTabIndex
                        ]
                        if tab.contentType == .terminal {
                            info["cwd"] = tab.workingDirectory
                            if !tab.state.foregroundProcess.isEmpty { info["process"] = tab.state.foregroundProcess }
                        }
                        if let item = inbox.items[tab.id] {
                            info["agent"] = [
                                "agent": item.agent, "state": item.state.rawValue,
                                "message": item.message ?? NSNull(), "tool": item.tool ?? NSNull(),
                                "updated_at": item.updatedAt.timeIntervalSince1970,
                                "owned": caller.map { CapabilityTokens.shared.owns($0, tab.id) } ?? false
                            ]
                        }
                        return info
                    }
                    return ["id": paneID.uuidString, "active": paneID == workspace.activePaneID, "tabs": tabs]
                }
                return [
                    "id": workspace.id.uuidString, "name": workspace.displayName, "folder": workspace.folderPath,
                    "active": workspace === controller.activeWorkspace,
                    "agent_task": AgentWorktree.looksLikeWorktree(workspace.folderPath),
                    "panes": panes
                ]
            }
            return ["active": controller === activeController, "workspaces": workspaces]
        }
        let orchestrator = OrchestratorController.shared
        return [
            "ok": true, "scope": "app", "windows": windows,
            "attention": inbox.items.values.filter(\.needsAttention).count,
            "orchestrator": [
                "running": orchestrator.isRunning,
                "pane_id": orchestrator.paneID?.uuidString ?? NSNull(),
                "tab_id": orchestrator.tabID?.uuidString ?? NSNull()
            ]
        ]
    }
}
