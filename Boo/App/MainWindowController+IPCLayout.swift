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
            equalizeSplitsAction(nil)
            reply(["ok": true])
        case "get_layout": reply(ipcLayout())
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

    private func ipcSplitPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        var args = json
        if args["direction"] == nil { args["direction"] = "right" }
        guard let edge = ipcDirection(args, reply: reply) else { return }
        guard let newID = splitActivePane(toward: edge) else {
            reply(["ok": false, "error": "no active pane"])
            return
        }
        reply(["ok": true, "pane_id": newID.uuidString])
    }

    private func ipcClosePane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let workspace = activeWorkspace else {
            reply(["ok": false, "error": "no active workspace"])
            return
        }
        var paneID = workspace.activePaneID
        if let idString = json["pane_id"] as? String {
            guard let id = UUID(uuidString: idString), workspace.pane(for: id) != nil else {
                reply(["ok": false, "error": "pane not found"])
                return
            }
            paneID = id
        }
        // Closing the last pane would close the workspace; that is not a layout change.
        guard workspace.splitTree.leafCount > 1 else {
            reply(["ok": false, "error": "cannot close the only pane"])
            return
        }
        workspace.activePaneID = paneID
        closePaneAction(nil)
        reply(["ok": true, "active_pane": workspace.activePaneID.uuidString])
    }

    private func ipcFocusPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        switch json["direction"] as? String {
        case "next": cyclePaneFocus(by: 1)
        case "previous": cyclePaneFocus(by: -1)
        default:
            guard let direction = ipcDirection(json, reply: reply) else { return }
            focusPane(direction)
        }
        reply(["ok": true, "active_pane": activeWorkspace?.activePaneID.uuidString ?? ""])
    }

    private func ipcResizePane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let direction = ipcDirection(json, reply: reply) else { return }
        let amount = (json["amount"] as? NSNumber)?.doubleValue ?? 10
        resizeActivePane(toward: direction, by: CGFloat(amount))
        reply(["ok": true])
    }

    private func ipcSwapPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let direction = ipcDirection(json, reply: reply) else { return }
        swapActivePane(toward: direction)
        reply(["ok": true])
    }

    /// Toggles zoom, or sets it with `"zoomed": true/false`.
    private func ipcZoomPane(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let workspace = activeWorkspace else {
            reply(["ok": false, "error": "no active workspace"])
            return
        }
        let wanted = (json["zoomed"] as? Bool) ?? (workspace.zoomedPaneID == nil)
        if wanted != (workspace.zoomedPaneID != nil) { toggleZoomPaneAction(nil) }
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

    /// Tree, on-screen pane frames (split container coordinates, top-left
    /// origin) and windows, for scripts and live checks.
    func ipcLayout() -> [String: Any] {
        guard let workspace = activeWorkspace else { return ["ok": false, "error": "no active workspace"] }
        let panes: [[String: Any]] = workspace.splitTree.leafIDs.map { id in
            var info: [String: Any] = ["id": id.uuidString, "active": id == workspace.activePaneID]
            guard let pv = paneViews[id], pv.window != nil, pv.window === window else {
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
