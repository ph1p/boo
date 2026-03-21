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
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView) { toggleSidebarAction(nil) }

    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customName = name
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].color = color
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customColor = (color == .clear) ? nil : color
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int) {
        appState.togglePin(at: index)
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int) {
        appState.moveWorkspace(from: source, to: destination)
        refreshToolbar()
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
    }

    func workspaceBar(_ bar: WorkspaceBarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].color = color
        refreshToolbar()
    }

    func workspaceBar(_ bar: WorkspaceBarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customColor = (color == .clear) ? nil : color
        refreshToolbar()
    }

    func workspaceBar(_ bar: WorkspaceBarView, togglePinForWorkspaceAt index: Int) {
        appState.togglePin(at: index)
        refreshToolbar()
    }

    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceFrom source: Int, to destination: Int) {
        appState.moveWorkspace(from: source, to: destination)
        refreshToolbar()
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
        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
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
        // Destroy all pane views for this workspace
        if let views = workspacePaneViews.removeValue(forKey: ws.id) {
            for (_, pv) in views {
                pv.stopAll()
            }
        }
        appState.removeWorkspace(at: index)
        if appState.workspaces.isEmpty {
            window?.close()
        } else {
            activateWorkspace(appState.activeWorkspaceIndex)
        }
    }

    func restoreWorkspaces() {
        openWorkspace(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func openWorkspace(path: String) {
        let workspace = Workspace(folderPath: path)
        appState.addWorkspace(workspace)
        activateWorkspace(appState.workspaces.count - 1)
    }

    func activateWorkspace(_ index: Int) {
        appState.setActiveWorkspace(index)
        guard let workspace = activeWorkspace else { return }

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

            if let pv = self.paneViews[ws.activePaneID] {
                self.window?.makeFirstResponder(pv.currentTerminalView)
            }

            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
        }
    }
}
