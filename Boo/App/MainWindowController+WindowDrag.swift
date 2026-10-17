import Cocoa

/// A workspace in transit between windows: the model plus its live pane
/// views, so terminals keep running while they move.
struct DetachedWorkspace {
    let workspace: Workspace
    let paneViews: [UUID: PaneView]
}

/// A tab taken out of its pane together with its live view (nil when the tab
/// was never displayed; the destination then starts a fresh session).
struct DetachedTab {
    let tab: Pane.Tab
    let ghosttyView: GhosttyView?
    let contentView: ContentViewProtocol?
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
            trackShell(of: pv.ghosttyView, paneID: paneID, tabID: ws.pane(for: paneID)?.activeTab?.id)
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

    /// Panes a dragged tab can drop on at `point`: those of the frontmost Boo
    /// window there (none over the desktop). Nil for an unmanaged window
    /// (tests), which then hit-tests its own panes.
    /// Highlight the window a dragged workspace would move into (none while
    /// over this window or empty screen, where release opens a new window).
    func updateWorkspaceDragTarget(atScreenPoint point: NSPoint?) {
        let manager = WindowManager.shared
        let target = point.flatMap { manager.controller(atScreenPoint: $0, excluding: self) }
        guard target !== workspaceDragTarget else { return }
        workspaceDragTarget?.setWorkspaceDropHighlighted(false)
        target?.setWorkspaceDropHighlighted(true)
        workspaceDragTarget = target
    }

    func setWorkspaceDropHighlighted(_ highlighted: Bool) {
        workspaceDropHighlight?.removeFromSuperview()
        workspaceDropHighlight = nil
        guard highlighted, let contentView = window?.contentView else { return }
        let overlay = TabDropIndicatorView(frame: contentView.bounds.insetBy(dx: 4, dy: 4))
        overlay.autoresizingMask = [.width, .height]
        contentView.addSubview(overlay)
        workspaceDropHighlight = overlay
    }

    func dropTargetPaneViews(atScreenPoint point: NSPoint) -> [UUID: PaneView]? {
        let manager = WindowManager.shared
        guard manager.isManaged(self) else { return nil }
        return manager.controller(atScreenPoint: point, excluding: nil)?.paneViews ?? [:]
    }

    func trackShell(of gv: GhosttyView?, paneID: UUID, tabID: UUID?) {
        guard let pid = gv?.shellPID, pid > 0 else { return }
        bridge.monitor.track(paneID: paneID, shellPID: pid, tabID: tabID)
    }
}

// MARK: - Moving tabs between windows

extension MainWindowController {
    /// A tab was dropped on a pane of `target` (another window): move it there
    /// with its live view. Moving a workspace's last tab closes that workspace
    /// after confirmation, and this window when nothing is left.
    func moveTab(
        source: PaneView, tabIndex: Int, toWindow target: MainWindowController,
        dest: PaneView, zone: TabDropZone
    ) {
        guard tabIndex >= 0, tabIndex < source.pane.tabs.count,
            let sourceWorkspace = appState.workspaceContainingPane(source.paneID)
        else { return }
        let tabID = source.pane.tabs[tabIndex].id
        let move = { [weak self, weak target] in
            guard let self, let target,
                let index = source.pane.tabs.firstIndex(where: { $0.id == tabID }),
                let destWorkspace = target.appState.workspaceContainingPane(dest.paneID),
                let moved = self.detachTab(from: source, at: index)
            else { return }
            let paneID = target.insertDroppedTab(
                moved.tab, ghosttyView: moved.ghosttyView, contentView: moved.contentView,
                into: dest, zone: zone, workspace: destWorkspace)
            target.trackShell(of: moved.ghosttyView, paneID: paneID, tabID: moved.tab.id)
            target.saveSession()
            target.window?.makeKeyAndOrderFront(nil)
            self.finishTabMoveOut(source: source, workspace: sourceWorkspace)
        }
        guard sourceWorkspace.totalTabCount == 1, let sheetWindow = target.window else {
            move()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move last tab out of \"\(sourceWorkspace.displayName)\"?"
        alert.informativeText = "This is the only tab in that workspace. Moving it will close the workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move & Close Workspace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheetWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            move()
        }
    }

    /// A tab was dropped outside every Boo window: open it in a new window
    /// there. A workspace's only tab takes its whole workspace along.
    func tearOffTab(source: PaneView, tabIndex: Int, atScreenPoint point: NSPoint) {
        let manager = WindowManager.shared
        guard manager.isManaged(self), manager.controller(atScreenPoint: point, excluding: nil) == nil,
            let workspace = appState.workspaceContainingPane(source.paneID)
        else { return }
        if workspace.totalTabCount == 1 {
            if let index = appState.workspaces.firstIndex(where: { $0 === workspace }) {
                dropWorkspace(at: index, atScreenPoint: point)
            }
            return
        }
        let size = window?.frame.size
        guard let detached = detachTabIntoWorkspace(source: source, tabIndex: tabIndex) else { return }
        manager.newWindow(adopting: detached, at: point, size: size)
    }

    /// Move a tab out of `source` into a new single-pane workspace for
    /// another window. Nil when it is the workspace's only tab.
    func detachTabIntoWorkspace(source: PaneView, tabIndex: Int) -> DetachedWorkspace? {
        guard let workspace = appState.workspaceContainingPane(source.paneID),
            workspace.totalTabCount > 1,
            let moved = detachTab(from: source, at: tabIndex)
        else { return nil }
        finishTabMoveOut(source: source, workspace: workspace)

        let ws = Workspace(folderPath: workspace.folderPath)
        let paneID = ws.activePaneID
        guard let pane = ws.pane(for: paneID) else { return nil }
        pane.stopAll()
        pane.insertTab(moved.tab, at: 0)
        let pv = PaneView(paneID: paneID, pane: pane)
        if let gv = moved.ghosttyView {
            pv.insertGhosttyView(gv, for: moved.tab.id)
        } else if let cv = moved.contentView {
            pv.insertContentView(cv, for: moved.tab.id)
        }
        return DetachedWorkspace(workspace: ws, paneViews: [paneID: pv])
    }

    /// Take a tab and its view out of `source` for another window.
    private func detachTab(from source: PaneView, at index: Int) -> DetachedTab? {
        guard let tab = source.pane.extractTab(at: index) else { return nil }
        let gv = tab.contentType == .terminal ? source.extractGhosttyView(for: tab.id) : nil
        let cv = tab.contentType != .terminal ? source.extractContentView(for: tab.id) : nil
        notifyTerminalClosed(for: tab.id)
        return DetachedTab(tab: tab, ghosttyView: gv, contentView: cv)
    }

    /// Tidy `source` after one of its tabs left for another window: show the
    /// next tab, or close the emptied pane, or the emptied workspace (and
    /// this window with its last workspace).
    private func finishTabMoveOut(source: PaneView, workspace: Workspace) {
        if source.pane.tabs.isEmpty {
            bridge.monitor.untrack(paneID: source.paneID)
        }
        if workspace.totalTabCount == 0 {
            if let index = appState.workspaces.firstIndex(where: { $0 === workspace }) {
                forceCloseWorkspace(at: index)
            }
            return
        }
        if !source.pane.tabs.isEmpty {
            source.startActiveSession()
            source.needsDisplay = true
            trackShell(of: source.ghosttyView, paneID: source.paneID, tabID: source.pane.activeTab?.id)
        } else if workspace === activeWorkspace {
            closeEmptyPane(source.paneID)
        } else {
            workspacePaneViews[workspace.id]?.removeValue(forKey: source.paneID)
            source.stopAll()
            _ = workspace.closePane(source.paneID)
        }
        refreshToolbar()
        saveSession()
    }
}
