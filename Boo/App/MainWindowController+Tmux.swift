import Cocoa

/// tmux windows shown as workspaces of this window; see `TmuxControlClient`.
extension MainWindowController: TmuxHost {
    func tmuxOpenWorkspace(
        window: String, name: String, tree: SplitTree, programs: [UUID: String], focus: Bool
    )
        -> UUID?
    {
        guard let first = tree.leafIDs.first else { return nil }
        let folder = activeWorkspace?.folderPath ?? AppSettings.shared.defaultFolder
        let workspace = Workspace(folderPath: folder, id: UUID(), splitTree: tree, activePaneID: first)
        workspace.customName = name
        workspace.tmuxWindowID = window
        for pane in tmuxPanes(programs, folder: folder) { workspace.restorePane(pane) }
        if focus {
            presentNewWorkspace(workspace)
        } else {
            // Shown in the bar; its bridges start when it is first activated.
            let active = appState.activeWorkspaceIndex
            appState.addWorkspace(workspace)
            appState.setActiveWorkspace(active)
            refreshToolbar()
        }
        return workspace.id
    }

    func tmuxApplyLayout(workspace id: UUID, tree: SplitTree, programs: [UUID: String]) {
        guard let workspace = appState.workspace(withID: id) else { return }
        let isVisible = workspace === activeWorkspace
        if isVisible { previousFocusedTabID = nil }
        let gone = workspace.adopt(tree: tree, newPanes: tmuxPanes(programs, folder: workspace.folderPath))
        for paneID in gone { workspacePaneViews[id]?.removeValue(forKey: paneID)?.stopAll() }
        guard isVisible else { return }
        splitContainer.update(tree: workspace.displayedTree)
        DispatchQueue.main.async { [weak self] in
            guard let self, let ws = self.activeWorkspace, ws.id == id else { return }
            for pv in self.paneViews.values {
                pv.tabDragCoordinator = self.tabDragCoordinator
                if pv.currentTerminalView == nil { pv.startActiveSession() }
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }

    func tmuxRenameWorkspace(_ id: UUID, name: String) {
        appState.workspace(withID: id)?.customName = name
        refreshToolbar()
    }

    func tmuxCloseWorkspace(_ id: UUID) {
        guard let index = appState.workspaces.firstIndex(where: { $0.id == id }) else { return }
        forceCloseWorkspace(at: index)
    }

    /// One single-tab pane per leaf, each running its bridge program.
    private func tmuxPanes(_ programs: [UUID: String], folder: String) -> [Pane] {
        programs.map { paneID, program in
            let pane = Pane(id: paneID)
            pane.addTab(workingDirectory: folder)
            if let tab = pane.tabs.last { GhosttyView.pendingLaunch[tab.id] = LaunchSpec(program: program) }
            return pane
        }
    }
}

extension MainWindowController {
    /// The active workspace, or a regular one when tmux owns it: tmux panes
    /// only show tmux, so files, browsers and plugin views open elsewhere.
    func contentWorkspace() -> Workspace? {
        guard let active = activeWorkspace else { return nil }
        guard active.tmuxWindowID != nil else { return active }
        if let index = appState.workspaces.lastIndex(where: { $0.tmuxWindowID == nil }) {
            activateWorkspace(index)
        } else {
            openWorkspace(path: active.folderPath)
        }
        return activeWorkspace
    }

    /// `paneView` shows a pane of a tmux window, in any Boo window.
    func isTmuxPane(_ paneView: PaneView) -> Bool {
        WindowManager.shared.controllers.contains {
            $0.appState.workspaceContainingPane(paneView.paneID)?.tmuxWindowID != nil
        }
    }
}
