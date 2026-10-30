import Cocoa
import SwiftUI

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
            pane.tmuxOwned = true
            if let tab = pane.tabs.last { GhosttyView.pendingLaunch[tab.id] = LaunchSpec(program: program) }
            return pane
        }
    }
}

extension MainWindowController {
    /// Switches to a regular workspace when tmux owns the active one (its
    /// panes only show tmux), opening one if needed. Returns the active workspace.
    func activateContentWorkspace() -> Workspace? {
        guard let active = activeWorkspace else { return nil }
        guard active.tmuxWindowID != nil else { return active }
        if let index = appState.workspaces.lastIndex(where: { $0.tmuxWindowID == nil }) {
            activateWorkspace(index)
        } else {
            openWorkspace(path: active.folderPath)
        }
        return activeWorkspace
    }

    /// Opens a new tmux window when tmux owns `workspace`.
    func openTmuxWindow(in workspace: Workspace?) -> Bool {
        guard let workspace, let tmux = TmuxControlClient.owning(workspace: workspace.id) else { return false }
        tmux.newWindow()
        return true
    }

    /// A plain terminal becomes a new tmux window; anything else opens in a
    /// regular workspace.
    func paneView(
        _ paneView: PaneView, redirectNewTab contentType: ContentType, workingDirectory: String, url: URL?,
        launch: LaunchSpec?
    ) -> UUID? {
        if contentType == .terminal, launch == nil,
            openTmuxWindow(in: appState.workspaceContainingPane(paneView.paneID))
        {
            return nil
        }
        return activateContentWorkspace().flatMap { paneViews[$0.activePaneID] }?
            .addNewTab(contentType: contentType, workingDirectory: workingDirectory, url: url, launch: launch)
    }

    func paneView(_ paneView: PaneView, redirectPluginView view: AnyView, title: String, icon: String) -> UUID? {
        activateContentWorkspace().flatMap { paneViews[$0.activePaneID] }?
            .addPluginViewTab(view: view, title: title, icon: icon)
    }
}
