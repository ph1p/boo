import Cocoa

// MARK: - IPC: pane layout and windows

extension MainWindowController {
    /// Layout commands: split, close, focus, resize, swap, zoom, equalize,
    /// inspect, moving the active workspace to a new window and merging all
    /// windows into the active one. False when
    /// `cmd` is not one of them.
    func handleIPCLayoutCommand(
        cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) -> Bool {
        switch cmd {
        case "split_pane": ipcSplitPane(json: json, reply: reply)
        case "close_pane": ipcClosePane(json: json, reply: reply)
        case "focus_pane": ipcFocusPane(json: json, reply: reply)
        case "resize_pane": ipcResizePane(json: json, reply: reply)
        case "swap_pane": ipcSwapPane(json: json, reply: reply)
        case "zoom_pane": ipcZoomPane(json: json, reply: reply)
        case "equalize_splits":
            guard ipcOnScreenPane(json, reply: reply) != nil else { return true }
            equalizeSplitsAction(nil)
            reply(["ok": true])
        case "get_layout": ipcGetLayout(json: json, reply: reply)
        case "move_workspace_to_new_window": ipcMoveWorkspaceToNewWindow(json: json, reply: reply)
        case "merge_all_windows":
            mergeAllWindows()
            reply(["ok": true, "workspaces": appState.workspaces.count])
        default: return false
        }
        return true
    }

    // MARK: Handlers

    /// `direction` is required; replies with an error when it is missing or unknown.
    private func ipcDirection(_ json: [String: Any], reply: ([String: Any]) -> Void) -> PaneDirection? {
        guard let name = json["direction"] as? String, let direction = PaneDirection(name: name) else {
            reply(["ok": false, "error": "direction must be left, right, up or down"])
            return nil
        }
        return direction
    }

    /// The pane named by `pane_id` (in any workspace of this window), else the
    /// active pane. Replies with an error and returns nil when there is none.
    func ipcTargetPane(_ json: [String: Any], reply: ([String: Any]) -> Void) -> (workspace: Workspace, paneID: UUID)? {
        if let idString = json["pane_id"] as? String {
            guard let id = UUID(uuidString: idString), let workspace = appState.workspaceContainingPane(id) else {
                reply(["ok": false, "error": "pane not found"])
                return nil
            }
            return (workspace, id)
        }
        guard let workspace = activeWorkspace else {
            reply(["ok": false, "error": "no active workspace"])
            return nil
        }
        return (workspace, workspace.activePaneID)
    }

    /// `ipcTargetPane`, limited to the on-screen workspace: focus, resize, swap,
    /// zoom and equalize work on the visible layout. Replies with an error for
    /// a pane in a background workspace.
    private func ipcOnScreenPane(
        _ json: [String: Any], reply: ([String: Any]) -> Void
    ) -> (
        workspace: Workspace, paneID: UUID
    )? {
        guard let target = ipcTargetPane(json, reply: reply) else { return nil }
        guard target.workspace === activeWorkspace else {
            reply(["ok": false, "error": "pane is in a background workspace; switch to it first"])
            return nil
        }
        return target
    }

    private func ipcSplitPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        var args = json
        if args["direction"] == nil { args["direction"] = "right" }
        guard let edge = ipcDirection(args, reply: reply), let target = ipcTargetPane(json, reply: reply) else {
            return
        }
        let command = (json["command"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let cwd = (json["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
        guard
            let newID = splitPane(
                target.paneID, in: target.workspace, toward: edge,
                focus: json["focus"] as? Bool ?? true, cwd: cwd, command: command)
        else {
            reply(["ok": false, "error": "pane not found"])
            return
        }
        // Background workspaces get their terminals when they are next shown.
        reply(["ok": true, "pane_id": newID.uuidString, "started": target.workspace === activeWorkspace])
    }

    private func ipcClosePane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let (workspace, paneID) = ipcTargetPane(json, reply: reply) else { return }
        // Closing the last pane would close the workspace; that is not a layout change.
        guard workspace.splitTree.leafCount > 1 else {
            reply(["ok": false, "error": "cannot close the only pane"])
            return
        }
        guard workspace === activeWorkspace else {
            // Background workspace: nothing on screen to re-layout.
            if let pane = workspace.pane(for: paneID) { notifyTerminalClosed(for: pane.tabs) }
            bridge.monitor.untrack(paneID: paneID)
            workspacePaneViews[workspace.id]?.removeValue(forKey: paneID)?.stopAll()
            _ = workspace.closePane(paneID)
            saveSession()
            reply(["ok": true, "active_pane": workspace.activePaneID.uuidString])
            return
        }
        workspace.activePaneID = paneID
        closePaneAction(nil)
        reply(["ok": true, "active_pane": workspace.activePaneID.uuidString])
    }

    /// Moves focus from `pane_id` (default: the active pane) by `direction`;
    /// with `pane_id` and no direction, focuses that pane.
    private func ipcFocusPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let (workspace, paneID) = ipcOnScreenPane(json, reply: reply) else { return }
        let name = json["direction"] as? String
        var direction: PaneDirection?
        if name != "next", name != "previous", name != nil || json["pane_id"] == nil {
            guard let parsed = ipcDirection(json, reply: reply) else { return }
            direction = parsed
        }
        if paneID != workspace.activePaneID { focusPane(paneID, in: workspace) }
        switch name {
        case "next": cyclePaneFocus(by: 1)
        case "previous": cyclePaneFocus(by: -1)
        default: if let direction { focusPane(direction) }
        }
        reply(["ok": true, "active_pane": activeWorkspace?.activePaneID.uuidString ?? ""])
    }

    private func ipcResizePane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let direction = ipcDirection(json, reply: reply), let target = ipcOnScreenPane(json, reply: reply)
        else { return }
        let amount = (json["amount"] as? NSNumber)?.doubleValue ?? 10
        resizeActivePane(toward: direction, by: CGFloat(amount), paneID: target.paneID)
        reply(["ok": true])
    }

    private func ipcSwapPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let direction = ipcDirection(json, reply: reply), let target = ipcOnScreenPane(json, reply: reply)
        else { return }
        swapActivePane(toward: direction, paneID: target.paneID)
        reply(["ok": true])
    }

    /// Toggles zoom, or sets it with `"zoomed": true/false`. Zooming in shows
    /// `pane_id` (default: the active pane) and focuses it.
    private func ipcZoomPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let (workspace, paneID) = ipcOnScreenPane(json, reply: reply) else { return }
        let wanted = (json["zoomed"] as? Bool) ?? (workspace.zoomedPaneID == nil)
        if wanted {
            if paneID != workspace.activePaneID { focusPane(paneID, in: workspace) }
            if workspace.zoomedPaneID != paneID, workspace.splitTree.leafCount > 1 {
                setZoomedPane(paneID, in: workspace)
            }
        } else if workspace.zoomedPaneID != nil {
            setZoomedPane(nil, in: workspace)
        }
        reply(["ok": true, "zoomed": workspace.zoomedPaneID != nil])
    }

    private func ipcMoveWorkspaceToNewWindow(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let index = (json["index"] as? Int) ?? appState.activeWorkspaceIndex
        let count = appState.workspaces.count
        moveWorkspaceToNewWindow(at: index)
        guard appState.workspaces.count < count else {
            reply(["ok": false, "error": "workspace cannot move (pinned, last, or out of range)"])
            return
        }
        reply(["ok": true, "windows": WindowManager.shared.controllers.count])
    }

    // MARK: Layout snapshot

    private func ipcGetLayout(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let target = ipcTargetPane(json, reply: reply) else { return }
        reply(ipcLayout(of: target.workspace))
    }

    /// Tree, on-screen pane frames (split container coordinates, top-left
    /// origin), each pane's tabs and windows, for scripts, agents and live checks.
    /// Panes of a background workspace have no frames.
    func ipcLayout(of workspace: Workspace) -> [String: Any] {
        let isVisible = workspace === activeWorkspace
        let panes: [[String: Any]] = workspace.splitTree.leafIDs.map { id in
            var info: [String: Any] = ["id": id.uuidString, "active": id == workspace.activePaneID]
            if let pane = workspace.pane(for: id) {
                info["tabs"] = pane.tabs.enumerated().map { index, tab in
                    var tabInfo: [String: Any] = [
                        "id": tab.id.uuidString, "title": tab.title, "type": tab.contentType.rawValue,
                        "active": index == pane.activeTabIndex
                    ]
                    if tab.contentType == .terminal {
                        tabInfo["cwd"] = tab.workingDirectory
                        if !tab.state.foregroundProcess.isEmpty { tabInfo["process"] = tab.state.foregroundProcess }
                    }
                    return tabInfo
                }
            }
            guard isVisible, let pv = paneViews[id], pv.window != nil, pv.window === window else {
                info["visible"] = false
                return info
            }
            info["visible"] = true
            info["frame"] = Self.ipcRect(pv.convert(pv.bounds, to: splitContainer), flippedIn: splitContainer)
            if let gv = pv.ghosttyView, gv.window != nil {
                info["terminal"] = Self.ipcRect(gv.convert(gv.bounds, to: splitContainer), flippedIn: splitContainer)
                if let grid = gv.gridSize {
                    info["grid"] = ["columns": Int(grid.columns), "rows": Int(grid.rows)]
                }
            }
            return info
        }
        let windows: [[String: Any]] = WindowManager.shared.controllers.map { controller in
            [
                "workspaces": controller.appState.workspaces.count,
                "active": controller === self
            ]
        }
        return [
            "ok": true,
            "workspace_id": workspace.id.uuidString,
            "workspace_visible": isVisible,
            "active_pane": workspace.activePaneID.uuidString,
            "zoomed_pane": workspace.zoomedPaneID?.uuidString ?? NSNull(),
            "container": ["width": splitContainer.bounds.width, "height": splitContainer.bounds.height],
            "tree": Self.ipcTree(workspace.splitTree),
            "panes": panes,
            "windows": windows
        ]
    }

    private static func ipcTree(_ tree: SplitTree) -> [String: Any] {
        switch tree {
        case .leaf(let id):
            return ["pane": id.uuidString]
        case .split(let direction, let first, let second, let ratio):
            return [
                "direction": direction == .horizontal ? "horizontal" : "vertical",
                "ratio": Double(ratio),
                "first": ipcTree(first),
                "second": ipcTree(second)
            ]
        }
    }

    private static func ipcRect(_ rect: NSRect, flippedIn view: NSView) -> [String: Double] {
        let y = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        return [
            "x": Double(rect.minX.rounded()), "y": Double(y.rounded()),
            "width": Double(rect.width.rounded()), "height": Double(rect.height.rounded())
        ]
    }
}
