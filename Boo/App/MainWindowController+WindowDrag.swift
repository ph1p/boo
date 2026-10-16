import Cocoa

/// A workspace in transit between windows: the model plus its live pane
/// views, so terminals keep running while they move.
struct DetachedWorkspace {
    let workspace: Workspace
    let paneViews: [UUID: PaneView]
}

// MARK: - Moving workspaces between windows

extension MainWindowController {
    /// A workspace pill was dropped outside this window: move the workspace
    /// into the window under the cursor, or into a new window there.
    func dropWorkspace(at index: Int, atScreenPoint point: NSPoint) {
        guard index >= 0, index < appState.workspaces.count, !appState.workspaces[index].isPinned else { return }
        let manager = WindowManager.shared
        if let target = manager.controller(atScreenPoint: point, excluding: self) {
            let dropIndex = target.workspaceDropIndex(atScreenPoint: point)
            guard let detached = detachWorkspace(at: index) else { return }
            target.adoptWorkspace(detached, at: dropIndex)
            target.window?.makeKeyAndOrderFront(nil)
            if appState.workspaces.isEmpty { window?.close() }
        } else {
            // Moving the only workspace into a new window would just move the window.
            guard appState.workspaces.count > 1 else { return }
            let size = window?.frame.size
            guard let detached = detachWorkspace(at: index) else { return }
            manager.newWindow(adopting: detached, at: point, size: size)
        }
    }

    /// Remove a workspace from this window without stopping its terminals.
    /// The caller must hand the result to `adoptWorkspace` and close this
    /// window when it has no workspaces left.
    func detachWorkspace(at index: Int) -> DetachedWorkspace? {
        guard index >= 0, index < appState.workspaces.count else { return nil }
        let ws = appState.workspaces[index]
        let wasActive = index == appState.activeWorkspaceIndex
        let views = workspacePaneViews.removeValue(forKey: ws.id) ?? [:]
        for pv in views.values {
            pv.persistContentStateToModel()
        }
        if wasActive {
            savePluginStateForActiveTab()
            if renderedWorkspaceID == ws.id {
                persistActiveWorkspaceSidebarState(for: ws)
            }
        }
        // Plugin bookkeeping and shell tracking are per window; the target
        // window re-tracks the panes in `adoptWorkspace`.
        for pane in ws.panes.values {
            notifyTerminalClosed(for: pane.tabs)
            bridge.monitor.untrack(paneID: pane.id)
        }
        appState.detachWorkspace(at: index)
        if renderedWorkspaceID == ws.id { renderedWorkspaceID = nil }
        guard !appState.workspaces.isEmpty else { return DetachedWorkspace(workspace: ws, paneViews: views) }
        if wasActive {
            activateWorkspace(appState.activeWorkspaceIndex)
        } else {
            refreshToolbar()
        }
        saveSession(persistSidebarState: false)
        return DetachedWorkspace(workspace: ws, paneViews: views)
    }

    /// Take over a workspace detached from another window and show it.
    /// `index` nil appends after the last workspace.
    func adoptWorkspace(_ detached: DetachedWorkspace, at index: Int? = nil) {
        let ws = detached.workspace
        for (paneID, pv) in detached.paneViews {
            pv.paneDelegate = self
            pv.tabDragCoordinator = tabDragCoordinator
            if let pid = pv.ghosttyView?.shellPID, pid > 0 {
                bridge.monitor.track(paneID: paneID, shellPID: pid, tabID: ws.pane(for: paneID)?.activeTab?.id)
            }
        }
        workspacePaneViews[ws.id] = detached.paneViews
        let dest = appState.insertWorkspace(ws, at: index ?? appState.workspaces.count)
        activateWorkspace(dest)
        saveSession()
    }

    /// Insertion index for a workspace dropped at `point` (screen coordinates):
    /// next to the pill under the cursor, else after the last workspace.
    func workspaceDropIndex(atScreenPoint point: NSPoint) -> Int {
        let vertical = sideWorkspaceBar != nil
        for (i, frame) in workspacePillScreenFrames() where frame.insetBy(dx: -4, dy: -4).contains(point) {
            let after = vertical ? point.y < frame.midY : point.x > frame.midX
            return after ? i + 1 : i
        }
        return appState.workspaces.count
    }
}
