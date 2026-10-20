import Foundation

// MARK: - IPC Socket Integration

extension MainWindowController {

    // MARK: - Command Dispatch

    /// Single command router shared by the unix socket (`BooSocketServer`) and
    /// the Remote Control web server (`RemoteControlServer`).
    func handleIPCCommand(
        cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) {
        if handleIPCLayoutCommand(cmd: cmd, json: json, reply: reply) { return }
        switch cmd {
        case "set_theme":
            ipcSetTheme(json: json, reply: reply)
        case "toggle_sidebar":
            ipcToggleSidebar(reply: reply)
        case "switch_workspace":
            ipcSwitchWorkspace(json: json, reply: reply)
        case "new_tab":
            ipcNewTab(json: json, reply: reply)
        case "new_workspace":
            ipcNewWorkspace(json: json, reply: reply)
        case "new_agent_task":
            ipcNewAgentTask(json: json, reply: reply)
        case "review_changes":
            ipcReviewChanges(json: json, reply: reply)
        case "new_window":
            WindowManager.shared.newWindow()
            reply(["ok": true, "windows": WindowManager.shared.controllers.count])
        case "send_text":
            ipcSendText(json: json, reply: reply)
        case "get_workspaces":
            ipcGetWorkspaces(reply: reply)
        case "agent_idle":
            ipcAgentIdle(json: json, reply: reply)
        case "get_state":
            remoteGetState(reply: reply)
        case "get_screen":
            if json["pane_id"] != nil || json["lines"] != nil {
                ipcReadPane(json: json, reply: reply)
            } else {
                remoteGetScreen(reply: reply)
            }
        case "send_key":
            remoteSendKey(json: json, reply: reply)
        case "select_pane":
            remoteSelectPane(json: json, reply: reply)
        case "select_tab":
            remoteSelectTab(json: json, reply: reply)
        default:
            reply(["ok": false, "error": "unknown control command: \(cmd)"])
        }
    }

    // MARK: - Individual Handlers

    private func ipcSetTheme(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let name = json["name"] as? String else {
            reply(["ok": false, "error": "missing theme name"])
            return
        }
        let available = TerminalTheme.themes.map { $0.name }
        guard available.contains(name) else {
            reply(["ok": false, "error": "unknown theme: \(name)"])
            return
        }
        AppSettings.shared.themeName = name
        reply(["ok": true, "theme": name])
    }

    private func ipcToggleSidebar(reply: @escaping ([String: Any]) -> Void) {
        toggleSidebar(userInitiated: true)
        reply(["ok": true, "visible": sidebarVisible])
    }

    private func ipcSwitchWorkspace(
        json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) {
        if let index = json["index"] as? Int {
            guard index >= 0, index < appState.workspaces.count else {
                reply(["ok": false, "error": "index out of range"])
                return
            }
            activateWorkspace(index)
            reply(["ok": true, "index": index])
        } else if let id = json["id"] as? String {
            if let index = appState.workspaces.firstIndex(where: { $0.id.uuidString == id }) {
                activateWorkspace(index)
                reply(["ok": true, "index": index])
            } else {
                reply(["ok": false, "error": "workspace not found: \(id)"])
            }
        } else {
            reply(["ok": false, "error": "missing index or id"])
        }
    }

    private func ipcNewTab(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let workspace = activeWorkspace,
            let pv = paneViews[workspace.activePaneID]
        else {
            reply(["ok": false, "error": "no active pane"])
            return
        }
        let cwd = json["cwd"] as? String ?? workspace.folderPath
        let launch = LaunchSpec.from(json: json)
        let tabID = pv.addNewTab(workingDirectory: cwd, launch: launch)
        reply(["ok": true, "tab_id": tabID?.uuidString ?? NSNull()])
    }

    private func ipcNewWorkspace(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let path = json["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        openWorkspace(path: path)
        reply(["ok": true])
    }

    /// Types `text` into the active pane, or the pane named by `pane_id`.
    /// `submit` pastes it (bracketed, one input for TUIs) and presses Return.
    private func ipcSendText(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let text = json["text"] as? String else {
            reply(["ok": false, "error": "missing text"])
            return
        }
        let submit = json["submit"] as? Bool ?? false
        if json["pane_id"] == nil && !submit {
            sendRawToActivePane(text)
            reply(["ok": true])
            return
        }
        guard let target = ipcTargetPane(json, reply: reply) else { return }
        guard let gv = terminalView(workspace: target.workspace, paneID: target.paneID) else {
            reply(["ok": false, "error": "pane has no running terminal"])
            return
        }
        if submit { gv.paste(text, submit: true) } else { gv.sendRaw(text) }
        reply(["ok": true])
    }

    /// Text of a pane in any workspace: the visible screen, or with `lines`
    /// the last lines of scrollback.
    private func ipcReadPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let target = ipcTargetPane(json, reply: reply) else { return }
        let tab = target.workspace.pane(for: target.paneID)?.activeTab
        guard let gv = terminalView(workspace: target.workspace, paneID: target.paneID) else {
            reply(["ok": false, "error": "pane has no running terminal"])
            return
        }
        let text = (json["lines"] as? Int).flatMap { gv.readRecentText(lines: min($0, 5000)) } ?? gv.readViewportText()
        reply([
            "ok": true, "pane_id": target.paneID.uuidString, "text": text ?? "",
            "title": tab?.title ?? "", "cwd": tab?.workingDirectory ?? ""
        ])
    }

    /// The terminal showing in a pane, background workspaces included.
    func terminalView(workspace: Workspace, paneID: UUID) -> GhosttyView? {
        guard let pv = workspacePaneViews[workspace.id]?[paneID] else { return nil }
        // currentTerminalView may be a TerminalScrollView wrapping the GhosttyView
        if let gv = pv.currentTerminalView as? GhosttyView { return gv }
        return (pv.currentTerminalView as? TerminalScrollView)?.ghosttyView
    }

    private func ipcReviewChanges(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let workspaceID: UUID?
        if json["pane_id"] != nil {
            guard let target = ipcTargetPane(json, reply: reply) else { return }
            workspaceID = target.workspace.id
        } else {
            workspaceID = (json["workspace_id"] as? String).flatMap(UUID.init(uuidString:)) ?? activeWorkspace?.id
        }
        let opened = workspaceID.map { openReview(workspaceID: $0) } ?? false
        reply(opened ? ["ok": true] : ["ok": false, "error": "no workspace"])
    }

    private func ipcAgentIdle(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let paneIDStr = json["pane_id"] as? String, let paneID = UUID(uuidString: paneIDStr) else {
            reply(["ok": false, "error": "missing pane_id"])
            return
        }
        guard let workspace = appState.workspaceContainingPane(paneID),
            let pane = workspace.pane(for: paneID)
        else {
            reply(["ok": false, "error": "pane not found"])
            return
        }
        signalActivity(
            workspace: workspace, pane: pane, tabIndex: pane.activeTabIndex, exitCode: 0, skipIfFocused: false)
        reply(["ok": true])
    }

    private func ipcGetWorkspaces(reply: @escaping ([String: Any]) -> Void) {
        let activeID = activeWorkspace?.id
        let list = appState.workspaces.enumerated().map { index, ws in
            [
                "index": index,
                "id": ws.id.uuidString,
                "path": ws.folderPath,
                "name": ws.displayName,
                "is_active": ws.id == activeID,
                "pane_count": ws.panes.count
            ] as [String: Any]
        }
        reply(["ok": true, "workspaces": list])
    }

    // MARK: - External Status Bar Segments

    func updateExternalStatusBarSegments(
        _ segments: [BooSocketServer.ExternalSegmentInfo]
    ) {
        statusBar.unregisterExternalSegments()
        for info in segments {
            let segment = ExternalStatusBarSegment(info: info)
            statusBar.registerPlugin(segment)
        }
        statusBar.needsDisplay = true
    }
}
