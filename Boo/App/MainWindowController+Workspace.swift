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
    func normalizeWorkspaceState() {
        appState.ensureUniquePaneIDsAcrossWorkspaces()
    }

    func persistActiveWorkspaceSidebarState(for workspace: Workspace? = nil) {
        let target = workspace ?? activeWorkspace
        target?.normalizePaneState()
        sidebarController.persistLiveState(for: target)
        debugLog(
            "[Sidebar] persistActiveWorkspaceSidebarState ws=\(target?.id.uuidString.prefix(8) ?? "nil") → sidebarState=\(String(describing: target?.sidebarState))"
        )
    }

    /// Shared close-workspace logic used by both toolbar and workspace bar delegates.
    func toolbarDidCloseWorkspace(at index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }
        let ws = appState.workspaces[index]
        guard !ws.isPinned else { return }

        if let location = unsavedEditorLocation(workspaceIndex: index) {
            confirmUnsavedEditorClose(location) { [weak self] in
                self?.presentCloseWorkspaceAlert(at: index)
            }
            return
        }

        presentCloseWorkspaceAlert(at: index)
    }

    func presentCloseWorkspaceAlert(at index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }

        let ws = appState.workspaces[index]
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
            guard let self,
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
                normalizeWorkspaceState()
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
        cancelPendingSidebarStateSave()
        for paneView in paneViews.values {
            paneView.persistContentStateToModel()
        }
        normalizeWorkspaceState()
        persistActiveWorkspaceSidebarState()
        savePluginStateForActiveTab()
        for (i, ws) in appState.workspaces.enumerated() {
            debugLog(
                "[Sidebar] saveSession ws[\(i)] id=\(ws.id.uuidString.prefix(8)) sidebarState=visible:\(String(describing: ws.sidebarState.isVisible)) width:\(ws.sidebarState.width ?? -1)"
            )
        }
        SessionStore.save(appState: appState)
    }

    func openWorkspace(path: String) {
        let previousIndex = appState.activeWorkspaceIndex
        let workspace = Workspace(folderPath: path)
        if AppSettings.shared.sidebarPerWorkspaceState {
            let currentSidebarState = sidebarController.captureLiveState()
            workspace.sidebarState = SidebarWorkspaceState(
                isVisible: currentSidebarState.isVisible,
                width: currentSidebarState.width
            )
        } else {
            workspace.sidebarState = sidebarController.resolveEffectiveSidebarState()
        }
        workspace.customName = appState.nextGeneratedWorkspaceName()
        configureInitialTab(for: workspace)
        appState.addWorkspace(workspace)
        if previousIndex >= 0 {
            appState.setActiveWorkspace(previousIndex)
        }
        activateWorkspace(appState.workspaces.count - 1)
        savePluginStateForActiveTab()
        SessionStore.save(appState: appState)
    }

    private func configureInitialTab(for workspace: Workspace) {
        guard let pane = workspace.pane(for: workspace.activePaneID) else { return }

        pane.stopAll()

        let defaultType = AppSettings.shared.defaultTabType
        let mainPage = AppSettings.shared.defaultMainPage.trimmingCharacters(in: .whitespacesAndNewlines)

        switch defaultType {
        case .terminal:
            _ = pane.addTab(workingDirectory: mainPage.isEmpty ? workspace.folderPath : mainPage)
        case .browser:
            let rawURL = mainPage.isEmpty ? AppSettings.shared.browserHomePage : mainPage
            let url = URL(string: rawURL) ?? ContentType.newTabURL
            let idx = pane.addTab(
                contentType: .browser,
                workingDirectory: workspace.folderPath,
                title: url.host ?? "New Tab"
            )
            pane.updateContentState(
                at: idx,
                .browser(BrowserContentState(title: url.host ?? "New Tab", url: url))
            )
        case .editor:
            let idx = pane.addTab(
                contentType: .editor,
                workingDirectory: workingDirectoryForMainPage(mainPage, workspacePath: workspace.folderPath),
                title: mainPage.isEmpty ? nil : (mainPage as NSString).lastPathComponent
            )
            pane.updateContentState(
                at: idx,
                .editor(
                    EditorContentState(
                        title: mainPage.isEmpty ? "Untitled" : (mainPage as NSString).lastPathComponent,
                        filePath: mainPage.isEmpty ? nil : mainPage
                    )
                )
            )
        case .imageViewer:
            let idx = pane.addTab(
                contentType: .imageViewer,
                workingDirectory: workingDirectoryForMainPage(mainPage, workspacePath: workspace.folderPath),
                title: mainPage.isEmpty ? nil : (mainPage as NSString).lastPathComponent
            )
            pane.updateContentState(
                at: idx,
                .imageViewer(
                    ImageViewerContentState(
                        title: mainPage.isEmpty ? "Image" : (mainPage as NSString).lastPathComponent,
                        filePath: mainPage
                    )
                )
            )
        case .markdownPreview:
            let idx = pane.addTab(
                contentType: .markdownPreview,
                workingDirectory: workingDirectoryForMainPage(mainPage, workspacePath: workspace.folderPath),
                title: mainPage.isEmpty ? nil : (mainPage as NSString).lastPathComponent
            )
            pane.updateContentState(
                at: idx,
                .markdownPreview(
                    MarkdownPreviewContentState(
                        title: mainPage.isEmpty ? "Markdown" : (mainPage as NSString).lastPathComponent,
                        filePath: mainPage
                    )
                )
            )
        case .pluginView:
            _ = pane.addTab(workingDirectory: workspace.folderPath)
        }
    }

    private func workingDirectoryForMainPage(_ mainPage: String, workspacePath: String) -> String {
        guard !mainPage.isEmpty else { return workspacePath }
        return (mainPage as NSString).deletingLastPathComponent.isEmpty
            ? workspacePath
            : (mainPage as NSString).deletingLastPathComponent
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
        let previousWorkspace = activeWorkspace
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

        appState.setActiveWorkspace(index)
        guard let workspace = activeWorkspace else { return }

        // Skip self-activation (startup restore): isVisible is uninitialized and would overwrite the loaded state.
        if let prev = previousWorkspace, prev.id != workspace.id {
            persistActiveWorkspaceSidebarState(for: prev)
        }

        savePluginStateForActiveTab()
        workspace.normalizePaneState()
        debugLog(
            "[WorkspaceSwitch] activate fromWorkspace=\(previousWorkspace?.id.uuidString ?? "none") toWorkspace=\(workspace.id.uuidString) targetPane=\(workspace.activePaneID.uuidString)"
        )

        if let activeTab = workspace.pane(for: workspace.activePaneID)?.activeTab {
            coordinator.restorePluginState(from: activeTab)
            previousFocusedTabID = activeTab.id
            if !AppSettings.shared.sidebarGlobalState {
                activePluginTabID = coordinator.selectedPluginTabID
            }
        } else {
            previousFocusedTabID = nil
            activePluginTabID = nil
            savedSidebarHeights = [:]
            savedSidebarScrollOffsets = [:]
            savedSidebarSectionOrder = [:]
        }

        let cwd = workspace.pane(for: workspace.activePaneID)?.activeTab?.workingDirectory ?? workspace.folderPath
        bridge.switchContext(paneID: workspace.activePaneID, workspaceID: workspace.id, workingDirectory: cwd)

        let restoredSidebarState = sidebarController.resolveEffectiveSidebarState(for: workspace)
        debugLog(
            "[Sidebar] activateWorkspace → resolvedState for ws=\(workspace.id.uuidString.prefix(8)) visible=\(String(describing: restoredSidebarState.isVisible)) width=\(restoredSidebarState.width ?? -1) storedState=\(String(describing: workspace.sidebarState))"
        )
        sidebarController.suppressSidebarStateSync += 1
        let activationGen = sidebarController.beginActivation()
        sidebarController.applyRestoredState(restoredSidebarState)

        refreshToolbar()
        // isRemoteSidebar/activeRemoteSession are now derived from bridge state,
        // which was just cleared by switchContext above.
        runPluginCycle(reason: .workspaceSwitched)

        // Rebuild split container with the workspace's tree
        renderedWorkspaceID = workspace.id
        splitContainer.update(tree: workspace.splitTree)
        sidebarController.suppressSidebarStateSync -= 1

        DispatchQueue.main.async { [weak self] in
            guard let self, let ws = self.activeWorkspace else { return }
            // splitContainer.update can reset the divider; re-apply after layout settles.
            debugLog(
                "[Sidebar] async restoreActiveWorkspaceWidth for ws=\(ws.id.uuidString.prefix(8)) stored=\(String(describing: ws.sidebarState))"
            )
            self.sidebarController.restoreActiveWorkspaceWidth(ifGeneration: activationGen)

            for (_, pane) in ws.panes {
                if let pv = self.paneViews[pane.id] {
                    // Ensure every pane has a session
                    if pv.currentTerminalView == nil {
                        pv.startActiveSession()
                    }
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
                debugLog(
                    "[WorkspaceSwitch] restoreResponder workspace=\(ws.id.uuidString) pane=\(targetPaneID.uuidString) ghostty=\(pv.ghosttyView != nil)"
                )
                self.window?.makeFirstResponder(pv.ghosttyView)
            }

            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            if let w = self.window { TrafficLightPositioner.apply(to: w) }
        }
    }
}
