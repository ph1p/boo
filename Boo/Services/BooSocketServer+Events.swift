import Foundation

// MARK: - Event Broadcasting

extension BooSocketServer {

    /// Broadcast an event to all clients subscribed to the given event name.
    /// Must be called on the socket `queue`.
    func broadcastEvent(name: String, data: [String: Any]) {
        let event: [String: Any] = ["event": name, "data": data]
        var deadFDs: [Int32] = []

        for (fd, events) in subscriptions {
            guard events.contains(name) || events.contains("*") else { continue }
            if !sendJSON(fd: fd, dict: event) {
                deadFDs.append(fd)
            }
        }

        // Clean up dead subscription clients
        for fd in deadFDs {
            subscriptions.removeValue(forKey: fd)
            clientSources[fd]?.cancel()
        }
    }

    /// Broadcast an event from any thread — dispatches to the socket queue.
    func emitEvent(name: String, data: [String: Any]) {
        nonisolated(unsafe) let sendableData = data
        queue.async { [self] in
            guard !subscriptions.isEmpty else { return }
            broadcastEvent(name: name, data: sendableData)
        }
    }

    // MARK: - Convenience Emitters

    func emitCwdChanged(path: String, isRemote: Bool, paneID: UUID) {
        emitEvent(
            name: "cwd_changed",
            data: [
                "path": path, "is_remote": isRemote, "pane_id": paneID.uuidString
            ])
    }

    func emitTitleChanged(title: String, paneID: UUID) {
        emitEvent(name: "title_changed", data: ["title": title, "pane_id": paneID.uuidString])
    }

    func emitProcessChanged(name: String, category: String?, paneID: UUID) {
        var data: [String: Any] = ["name": name, "pane_id": paneID.uuidString]
        if let cat = category { data["category"] = cat }
        emitEvent(name: "process_changed", data: data)
    }

    func emitRemoteSessionChanged(session: RemoteSessionType?, paneID: UUID) {
        if let session {
            var data = Self.serializeRemoteSession(session)
            data["active"] = true
            data["pane_id"] = paneID.uuidString
            emitEvent(name: "remote_session_changed", data: data)
        } else {
            emitEvent(
                name: "remote_session_changed",
                data: [
                    "active": false, "pane_id": paneID.uuidString
                ])
        }
    }

    func emitFocusChanged(paneID: UUID) {
        emitEvent(name: "focus_changed", data: ["pane_id": paneID.uuidString])
    }

    func emitWorkspaceSwitched(workspaceID: UUID) {
        emitEvent(name: "workspace_switched", data: ["workspace_id": workspaceID.uuidString])
    }

    func emitThemeChanged(name: String, isDark: Bool) {
        emitEvent(name: "theme_changed", data: ["name": name, "is_dark": isDark])
    }

    func emitSettingsChanged(topic: String) {
        emitEvent(name: "settings_changed", data: ["topic": topic])
    }

    func emitCommandStarted(command: String, paneID: UUID) {
        emitEvent(name: "cmd_started", data: ["command": command, "pane_id": paneID.uuidString])
    }

    func emitCommandEnded(result: CommandResult, paneID: UUID) {
        emitEvent(
            name: "cmd_ended",
            data: [
                "command": result.command,
                "exit_code": result.exitCode,
                "duration": result.duration,
                "pane_id": paneID.uuidString
            ])
    }
}
