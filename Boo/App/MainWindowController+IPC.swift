import Foundation

// MARK: - IPC Socket Integration

extension MainWindowController {

    /// Wire up the socket server's control command handler and event broadcasting.
    /// Called once during init, after bridge subscription.
    func setupIPCHandlers() {
        // Control commands from socket → MainActor handlers
        BooSocketServer.shared.onControlCommand = { [weak self] cmd, json, reply in
            DispatchQueue.main.async {
                guard let self else {
                    reply(["ok": false, "error": "window closed"])
                    return
                }
                self.handleIPCCommand(cmd: cmd, json: json, reply: reply)
            }
        }

        // External status bar segment changes
        BooSocketServer.shared.onExternalSegmentsChanged = { [weak self] segments in
            guard let self else { return }
            self.updateExternalStatusBarSegments(segments)
        }
    }

    // MARK: - Command Dispatch

    private func handleIPCCommand(
        cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) {
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
        case "send_text":
            ipcSendText(json: json, reply: reply)
        case "get_workspaces":
            ipcGetWorkspaces(reply: reply)
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
        pv.addNewTab(workingDirectory: cwd)
        reply(["ok": true])
    }

    private func ipcNewWorkspace(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let path = json["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        openWorkspace(path: path)
        reply(["ok": true])
    }

    private func ipcSendText(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let text = json["text"] as? String else {
            reply(["ok": false, "error": "missing text"])
            return
        }
        sendRawToActivePane(text)
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

    private func updateExternalStatusBarSegments(
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
