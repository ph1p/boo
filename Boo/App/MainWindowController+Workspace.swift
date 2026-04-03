import Cocoa

// MARK: - ToolbarViewDelegate

extension MainWindowController: ToolbarViewDelegate {
    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int) {
        guard index != appState.activeWorkspaceIndex else { return }
        activateWorkspace(index)
    }

    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int) {
        toolbarDidCloseWorkspace(at: index)
    }

    func toolbar(_ toolbar: ToolbarView, didSelectTabAt index: Int) {}
    func toolbar(_ toolbar: ToolbarView, didCloseTabAt index: Int) {}
    func toolbarDidRequestNewTab(_ toolbar: ToolbarView) { newTabAction(nil) }
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView) { toggleSidebar(userInitiated: true) }

    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customName = name
        refreshToolbar()
        saveSession()
    }

    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].color = color
        refreshToolbar()
        saveSession()
    }

    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customColor = (color == .clear) ? nil : color
        refreshToolbar()
        saveSession()
    }

    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int) {
        appState.togglePin(at: index)
        refreshToolbar()
        saveSession()
    }

    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int) {
        appState.moveWorkspace(from: source, to: destination)
        refreshToolbar()
        saveSession()
    }

    func toolbarDidRequestNewWorkspace(_ toolbar: ToolbarView) {
        newWorkspaceAction(nil)
    }
}

// MARK: - WorkspaceBarViewDelegate

extension MainWindowController: WorkspaceBarViewDelegate {
    func workspaceBar(_ bar: WorkspaceBarView, didSelectAt index: Int) {
        guard index != appState.activeWorkspaceIndex else { return }
        activateWorkspace(index)
    }

    func workspaceBar(_ bar: WorkspaceBarView, didCloseAt index: Int) {
        toolbarDidCloseWorkspace(at: index)
    }

    func workspaceBar(_ bar: WorkspaceBarView, renameWorkspaceAt index: Int, to name: String) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customName = name
        refreshToolbar()
        saveSession()
    }

    func workspaceBar(_ bar: WorkspaceBarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].color = color
        refreshToolbar()
        saveSession()
    }

    func workspaceBar(_ bar: WorkspaceBarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customColor = (color == .clear) ? nil : color
        refreshToolbar()
        saveSession()
    }

    func workspaceBar(_ bar: WorkspaceBarView, togglePinForWorkspaceAt index: Int) {
        appState.togglePin(at: index)
        refreshToolbar()
        saveSession()
    }

    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceFrom source: Int, to destination: Int) {
        appState.moveWorkspace(from: source, to: destination)
        refreshToolbar()
        saveSession()
    }

    func workspaceBarDidRequestNewWorkspace(_ bar: WorkspaceBarView) {
        newWorkspaceAction(nil)
    }
}

// MARK: - Workspace Management

extension MainWindowController {
    /// Shared close-workspace logic used by both toolbar and workspace bar delegates.
    func toolbarDidCloseWorkspace(at index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }
        let ws = appState.workspaces[index]
        guard !ws.isPinned else { return }

        let wsID = ws.id
        let totalTabs = ws.totalTabCount
        let alert = NSAlert()
        alert.messageText = "Close workspace \"\(ws.displayName)\"?"
        if ws.panes.count > 1 || totalTabs > 1 {
            alert.informativeText =
                "This will close \(ws.panes.count) pane\(ws.panes.count == 1 ? "" : "s") and \(totalTabs) tab\(totalTabs == 1 ? "" : "s")."
        } else {
            alert.informativeText = "This workspace and its terminal session will be closed."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Workspace")
        alert.addButton(withTitle: "Cancel")

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self,
                let resolvedIndex = self.appState.workspaces.firstIndex(where: { $0.id == wsID })
            else { return }
            self.forceCloseWorkspace(at: resolvedIndex)
        }
    }

    func forceCloseWorkspace(at index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }
        let ws = appState.workspaces[index]
        for pane in ws.panes.values {
            notifyTerminalClosed(for: pane.tabs)
        }
        // Destroy all pane views for this workspace
        if let views = workspacePaneViews.removeValue(forKey: ws.id) {
            for (_, pv) in views {
                pv.stopAll()
            }
        }
        appState.removeWorkspace(at: index)
        if appState.workspaces.isEmpty {
            saveSession()
            window?.close()
        } else {
            saveSession()
            activateWorkspace(appState.activeWorkspaceIndex)
        }
    }

    func restoreWorkspaces() {
        if let snapshot = SessionStore.load() {
            let restored = SessionStore.workspaces(from: snapshot)
            if !restored.isEmpty {
                for ws in restored {
                    appState.addWorkspace(ws)
                }
                let safeIndex = min(
                    max(snapshot.activeWorkspaceIndex, 0),
                    appState.workspaces.count - 1
                )
                activateWorkspace(safeIndex)
                return
            }
        }
        openWorkspace(path: AppSettings.shared.defaultFolder)
    }

    func saveSession() {
        SessionStore.save(appState: appState)
    }

    func openWorkspace(path: String) {
        let previousIndex = appState.activeWorkspaceIndex
        let workspace = Workspace(folderPath: path)
        appState.addWorkspace(workspace)
        if previousIndex >= 0 {
            appState.setActiveWorkspace(previousIndex)
        }
        activateWorkspace(appState.workspaces.count - 1)
        saveSession()
    }

    /// Collects screen-space rects for all workspace pills across toolbar and side bar.
    func workspacePillScreenFrames() -> [(index: Int, screenFrame: NSRect)] {
        var results: [(Int, NSRect)] = []
        results += toolbar.workspacePillScreenFrames()
        if let bar = sideWorkspaceBar {
            results += bar.workspacePillScreenFrames()
        }
        return results
    }

    func activateWorkspace(_ index: Int) {
        // Save the currently focused pane before switching away.
        if let oldWS = activeWorkspace, let focusedView = window?.firstResponder as? NSView {
            for (paneID, pv) in paneViews {
                if pv.currentTerminalView === focusedView || pv.isDescendant(of: focusedView)
                    || focusedView.isDescendant(of: pv)
                {
                    oldWS.activePaneID = paneID
                    break
                }
            }
        }

        savePluginStateForActiveTab()

        appState.setActiveWorkspace(index)
        guard let workspace = activeWorkspace else { return }

        if let activeTab = workspace.pane(for: workspace.activePaneID)?.activeTab {
            coordinator.restorePluginState(from: activeTab)
            previousFocusedTabID = activeTab.id
        } else {
            previousFocusedTabID = nil
            savedSidebarHeights = [:]
            savedSidebarScrollOffsets = [:]
        }

        let cwd = workspace.pane(for: workspace.activePaneID)?.activeTab?.workingDirectory ?? workspace.folderPath
        bridge.switchContext(paneID: workspace.activePaneID, workspaceID: workspace.id, workingDirectory: cwd)

        refreshToolbar()
        // isRemoteSidebar/activeRemoteSession are now derived from bridge state,
        // which was just cleared by switchContext above.
        runPluginCycle(reason: .workspaceSwitched)

        // Rebuild split container with the workspace's tree
        splitContainer.update(tree: workspace.splitTree)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let ws = self.activeWorkspace else { return }

            for (_, pv) in self.paneViews {
                // Ensure every pane has a session
                if pv.currentTerminalView == nil {
                    pv.startActiveSession()
                }
            }

            // Restore focus to the last focused pane, or the first pane.
            let targetPaneID: UUID
            if self.paneViews[ws.activePaneID] != nil {
                targetPaneID = ws.activePaneID
            } else {
                targetPaneID = ws.splitTree.leafIDs.first ?? ws.activePaneID
            }
            if let pv = self.paneViews[targetPaneID] {
                ws.activePaneID = targetPaneID
                self.window?.makeFirstResponder(pv.ghosttyView)
            }

            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }
}
