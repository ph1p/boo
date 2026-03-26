import Cocoa
import Foundation

// MARK: - Query & Control Commands

extension ExtermSocketServer {

    // MARK: - Query: get_context

    func handleGetContext(clientFD: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ctx = AppStore.shared.context
            let dict = Self.serializeContext(ctx)
            self.queue.async {
                guard self.clientSources[clientFD] != nil else { return }
                self.sendJSON(fd: clientFD, dict: ["ok": true, "context": dict])
            }
        }
    }

    static func serializeContext(_ ctx: TerminalContext) -> [String: Any] {
        var dict: [String: Any] = [
            "terminal_id": ctx.terminalID.uuidString,
            "cwd": ctx.cwd,
            "process_name": ctx.processName,
            "pane_count": ctx.paneCount,
            "tab_count": ctx.tabCount,
            "is_remote": ctx.isRemote,
            "environment": ctx.environmentLabel,
        ]
        if let remote = ctx.remoteSession {
            dict["remote_session"] = serializeRemoteSession(remote)
        }
        if let remoteCwd = ctx.remoteCwd {
            dict["remote_cwd"] = remoteCwd
        }
        if let git = ctx.gitContext {
            dict["git"] = [
                "branch": git.branch,
                "repo_root": git.repoRoot,
                "is_dirty": git.isDirty,
                "changed_count": git.changedFileCount,
                "staged_count": git.stagedCount,
                "ahead": git.aheadCount,
                "behind": git.behindCount,
                "last_commit": git.lastCommitShort as Any,
            ] as [String: Any]
        }
        return dict
    }

    static func serializeRemoteSession(_ session: RemoteSessionType) -> [String: Any] {
        switch session {
        case .ssh(let host, let alias):
            var dict: [String: Any] = ["type": "ssh", "host": host]
            if let alias { dict["alias"] = alias }
            return dict
        case .mosh(let host):
            return ["type": "mosh", "host": host]
        case .container(let target, let tool):
            return ["type": "container", "target": target, "tool": tool.rawValue]
        }
    }

    // MARK: - Query: get_theme

    func handleGetTheme(clientFD: Int32) {
        let theme = AppSettings.shared.theme
        sendJSON(fd: clientFD, dict: [
            "ok": true,
            "theme": [
                "name": theme.name,
                "is_dark": theme.isDark,
            ] as [String: Any],
        ])
    }

    // MARK: - Query: get_settings

    func handleGetSettings(clientFD: Int32) {
        let s = AppSettings.shared
        sendJSON(fd: clientFD, dict: [
            "ok": true,
            "settings": [
                "theme_name": s.themeName,
                "auto_theme": s.autoTheme,
                "font_name": s.fontName,
                "font_size": s.fontSize,
                "cursor_style": s.cursorStyle.label.lowercased(),
                "sidebar_position": s.sidebarPosition == .left ? "left" : "right",
                "sidebar_density": s.sidebarDensity == .compact ? "compact" : "comfortable",
                "show_hidden_files": s.showHiddenFiles,
                "auto_check_updates": s.autoCheckUpdates,
                "status_bar_show_path": s.statusBarShowPath,
                "status_bar_show_time": s.statusBarShowTime,
                "status_bar_show_pane_info": s.statusBarShowPaneInfo,
                "status_bar_show_shell": s.statusBarShowShell,
                "status_bar_show_connection": s.statusBarShowConnection,
            ] as [String: Any],
        ])
    }

    // MARK: - Query: list_themes

    func handleListThemes(clientFD: Int32) {
        let names = TerminalTheme.themes.map { $0.name }
        sendJSON(fd: clientFD, dict: ["ok": true, "themes": names])
    }

    // MARK: - Control Commands (dispatched to MainActor)

    func handleControlCommand(cmd: String, json: [String: Any], clientFD: Int32) {
        guard let handler = onControlCommand else {
            sendResponse(fd: clientFD, ok: false, error: "app not ready")
            return
        }
        let fd = clientFD
        handler(cmd, json) { [weak self] response in
            self?.queue.async {
                self?.sendJSON(fd: fd, dict: response)
            }
        }
    }

    // MARK: - Subscriptions

    /// Available event names for subscription.
    static let availableEvents: Set<String> = [
        "cwd_changed", "title_changed", "process_changed",
        "remote_session_changed", "focus_changed", "workspace_switched",
        "theme_changed", "settings_changed",
    ]

    func handleSubscribe(json: [String: Any], clientFD: Int32) {
        guard let events = json["events"] as? [String], !events.isEmpty else {
            sendResponse(fd: clientFD, ok: false, error: "missing events array")
            return
        }

        var resolved: Set<String>
        if events.contains("*") {
            resolved = Self.availableEvents
        } else {
            resolved = Set(events).intersection(Self.availableEvents)
        }

        if resolved.isEmpty {
            sendResponse(fd: clientFD, ok: false, error: "no valid events")
            return
        }

        var existing = subscriptions[clientFD] ?? []
        existing.formUnion(resolved)
        subscriptions[clientFD] = existing
        sendJSON(fd: clientFD, dict: ["ok": true, "subscribed": Array(existing).sorted()])
    }

    func handleUnsubscribe(json: [String: Any], clientFD: Int32) {
        guard let events = json["events"] as? [String] else {
            sendResponse(fd: clientFD, ok: false, error: "missing events array")
            return
        }

        if events.contains("*") {
            subscriptions.removeValue(forKey: clientFD)
        } else if var existing = subscriptions[clientFD] {
            existing.subtract(events)
            if existing.isEmpty {
                subscriptions.removeValue(forKey: clientFD)
            } else {
                subscriptions[clientFD] = existing
            }
        }
        sendResponse(fd: clientFD, ok: true)
    }

    // MARK: - Status Bar Commands

    func handleStatusBarCommand(cmd: String, json: [String: Any], clientFD: Int32) {
        switch cmd {
        case "statusbar.set":
            handleStatusBarSet(json: json, clientFD: clientFD)
        case "statusbar.clear":
            handleStatusBarClear(json: json, clientFD: clientFD)
        case "statusbar.list":
            handleStatusBarList(clientFD: clientFD)
        default:
            sendResponse(fd: clientFD, ok: false, error: "unknown statusbar command: \(cmd)")
        }
    }

    private func handleStatusBarSet(json: [String: Any], clientFD: Int32) {
        guard let id = json["id"] as? String, !id.isEmpty,
            let text = json["text"] as? String
        else {
            sendResponse(fd: clientFD, ok: false, error: "missing id or text")
            return
        }

        let icon = json["icon"] as? String
        let tint = json["tint"] as? String
        let posStr = json["position"] as? String ?? "right"
        let position: StatusBarPosition = posStr == "left" ? .left : .right
        let priority = json["priority"] as? Int ?? 50

        let segment = ExternalSegmentInfo(
            id: id, text: text, icon: icon, tint: tint,
            position: position, priority: priority, ownerFD: clientFD
        )
        externalSegments[id] = segment
        sendResponse(fd: clientFD, ok: true)
        notifyExternalSegmentsChanged()
    }

    private func handleStatusBarClear(json: [String: Any], clientFD: Int32) {
        guard let id = json["id"] as? String else {
            sendResponse(fd: clientFD, ok: false, error: "missing id")
            return
        }
        externalSegments.removeValue(forKey: id)
        sendResponse(fd: clientFD, ok: true)
        notifyExternalSegmentsChanged()
    }

    private func handleStatusBarList(clientFD: Int32) {
        let list = externalSegments.values.map {
            [
                "id": $0.id,
                "text": $0.text,
                "icon": $0.icon as Any,
                "position": $0.position == .left ? "left" : "right",
                "priority": $0.priority,
            ] as [String: Any]
        }
        sendJSON(fd: clientFD, dict: ["ok": true, "segments": list])
    }

}
