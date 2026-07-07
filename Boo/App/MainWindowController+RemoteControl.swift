import CGhostty
import Cocoa

// MARK: - Remote Control (web interface)

extension MainWindowController {

    /// Wire the remote control server into the shared IPC command router.
    /// Called once during init, next to `setupIPCHandlers()`.
    func setupRemoteControlHandlers() {
        RemoteControlServer.shared.onCommand = { [weak self] cmd, json, reply in
            DispatchQueue.main.async {
                guard let self else {
                    reply(["ok": false, "error": "window closed"])
                    return
                }
                self.handleIPCCommand(cmd: cmd, json: json, reply: reply)
            }
        }
    }

    // MARK: - State / Screen

    func remoteGetState(reply: @escaping ([String: Any]) -> Void) {
        let activeID = activeWorkspace?.id
        let workspaces = appState.workspaces.enumerated().map { index, ws in
            [
                "index": index,
                "name": ws.displayName,
                "path": ws.folderPath,
                "active": ws.id == activeID
            ] as [String: Any]
        }

        var panes: [[String: Any]] = []
        if let ws = activeWorkspace {
            for paneID in ws.splitTree.leafIDs {
                guard let pane = ws.pane(for: paneID) else { continue }
                let tabs = pane.tabs.enumerated().map { index, tab in
                    [
                        "index": index,
                        "title": tab.title,
                        "active": index == pane.activeTabIndex
                    ] as [String: Any]
                }
                panes.append([
                    "id": paneID.uuidString,
                    "active": paneID == ws.activePaneID,
                    "tabs": tabs
                ])
            }
        }
        let theme = AppSettings.shared.theme
        reply([
            "ok": true,
            "workspaces": workspaces,
            "panes": panes,
            "theme": [
                "name": theme.name,
                "is_dark": theme.isDark,
                "background": theme.background.hexString,
                "foreground": theme.foreground.hexString,
                "cursor": theme.cursor.hexString,
                "accent": theme.accentColor.hexString,
                "ansi": theme.ansiColors.map { $0.hexString }
            ] as [String: Any]
        ])
    }

    func remoteGetScreen(reply: @escaping ([String: Any]) -> Void) {
        guard let ws = activeWorkspace, let gv = activeGhosttyView else {
            reply(["ok": true, "text": "", "title": "No active terminal", "cwd": ""])
            return
        }
        let pane = ws.pane(for: ws.activePaneID)
        reply([
            "ok": true,
            "text": gv.readViewportText() ?? "",
            "title": pane?.activeTab?.title ?? "",
            "cwd": pane?.activeTab?.workingDirectory ?? ""
        ])
    }

    // MARK: - Input

    /// Named key → (macOS key code, modifiers, text). Mirrors clearScreenAction's
    /// synthetic-key approach so ghostty encodes per terminal mode.
    func remoteSendKey(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let key = json["key"] as? String else {
            reply(["ok": false, "error": "missing key"])
            return
        }
        guard let gv = activeGhosttyView else {
            reply(["ok": false, "error": "no active terminal"])
            return
        }
        switch key {
        case "enter": gv.sendKey(keyCode: 0x24, mods: GHOSTTY_MODS_NONE, text: "\r")
        case "tab": gv.sendKey(keyCode: 0x30, mods: GHOSTTY_MODS_NONE, text: "\t")
        case "escape": gv.sendKey(keyCode: 0x35, mods: GHOSTTY_MODS_NONE, text: "\u{1b}")
        case "backspace": gv.sendKey(keyCode: 0x33, mods: GHOSTTY_MODS_NONE, text: "\u{7f}")
        case "up": gv.sendKey(keyCode: 0x7E, mods: GHOSTTY_MODS_NONE)
        case "down": gv.sendKey(keyCode: 0x7D, mods: GHOSTTY_MODS_NONE)
        case "left": gv.sendKey(keyCode: 0x7B, mods: GHOSTTY_MODS_NONE)
        case "right": gv.sendKey(keyCode: 0x7C, mods: GHOSTTY_MODS_NONE)
        case "ctrl_c": gv.sendKey(keyCode: 0x08, mods: GHOSTTY_MODS_CTRL, text: "c")
        case "ctrl_d": gv.sendKey(keyCode: 0x02, mods: GHOSTTY_MODS_CTRL, text: "d")
        case "ctrl_z": gv.sendKey(keyCode: 0x06, mods: GHOSTTY_MODS_CTRL, text: "z")
        case "ctrl_l": gv.sendKey(keyCode: 0x25, mods: GHOSTTY_MODS_CTRL, text: "l")
        default:
            reply(["ok": false, "error": "unknown key: \(key)"])
            return
        }
        reply(["ok": true])
    }

    func remoteSelectPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let idStr = json["id"] as? String, let paneID = UUID(uuidString: idStr) else {
            reply(["ok": false, "error": "missing pane id"])
            return
        }
        guard let ws = activeWorkspace, ws.pane(for: paneID) != nil else {
            reply(["ok": false, "error": "pane not found"])
            return
        }
        ws.activePaneID = paneID
        paneViews[paneID]?.focusActiveView()
        runPluginCycle(reason: .focusChanged)
        reply(["ok": true])
    }

    func remoteSelectTab(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let index = json["index"] as? Int else {
            reply(["ok": false, "error": "missing index"])
            return
        }
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID),
            let pv = paneViews[ws.activePaneID],
            index >= 0, index < pane.tabs.count
        else {
            reply(["ok": false, "error": "tab index out of range"])
            return
        }
        pv.activateTab(index)
        reply(["ok": true])
    }

    // MARK: - Menu Actions

    @objc func toggleRemoteControlAction(_ sender: Any?) {
        let server = RemoteControlServer.shared
        if server.isRunning {
            server.stop()
            BooAlert.showTransient("Remote Control server stopped")
        } else {
            let port = UInt16(AppSettings.shared.remoteControlPort)
            guard server.start(port: port) else {
                BooAlert.showError(
                    title: "Remote Control",
                    message: "Could not start server on port \(port). The port may be in use.",
                    window: window)
                return
            }
            showRemoteControlURLAlert()
        }
    }

    @objc func copyRemoteControlURLAction(_ sender: Any?) {
        let server = RemoteControlServer.shared
        guard server.isRunning else {
            BooAlert.showTransient("Remote Control server is not running")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.accessURL, forType: .string)
        BooAlert.showTransient("Remote Control URL copied")
    }

    private func showRemoteControlURLAlert() {
        let url = RemoteControlServer.shared.accessURL
        let alert = NSAlert()
        alert.messageText = "Remote Control Server Running"
        alert.informativeText =
            "Open this URL on any device in your network:\n\n\(url)\n\n"
            + "The link contains a session token — anyone with it can control this terminal."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy URL")
        alert.addButton(withTitle: "OK")
        let respond = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
        if let w = window {
            alert.beginSheetModal(for: w, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}

// MARK: - Menu Validation

extension MainWindowController: NSMenuItemValidation {
    /// Pull-based menu state — AppKit calls this before showing the menu, so
    /// the Remote Control items always reflect the server without manual pokes.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleRemoteControlAction(_:)):
            menuItem.title =
                RemoteControlServer.shared.isRunning
                ? "Stop Remote Control Server" : "Start Remote Control Server"
            return true
        case #selector(copyRemoteControlURLAction(_:)):
            return RemoteControlServer.shared.isRunning
        default:
            return true
        }
    }
}
