import Cocoa

// MARK: - Pane Management

extension MainWindowController {
    /// Update all pane views' close-button visibility based on total pane count.
    func updatePaneCloseButtons() {
        let multiPane = activeWorkspace.map { $0.panes.count > 1 } ?? false
        let activePaneID = activeWorkspace?.activePaneID
        let zoomedPaneID = activeWorkspace?.zoomedPaneID
        for (paneID, pv) in paneViews {
            pv.showCloseOnSingleTab = multiPane
            pv.isFocused = paneID == activePaneID
            pv.isZoomed = paneID == zoomedPaneID
            // Re-bound every pass: pane views can move to another window.
            pv.onUnzoomRequested = { [weak self] in
                guard let self, let workspace = self.activeWorkspace else { return }
                self.setZoomedPane(nil, in: workspace)
            }
            pv.paneControls.onAction = { [weak self, weak pv] action in
                guard let self, let pv else { return }
                self.handlePaneControl(action, in: pv)
            }
            pv.paneControls.menuProvider = { [weak self, weak pv] in
                guard let self, let pv else { return nil }
                return self.paneControlsMenu(for: pv)
            }
            pv.paneControls.profileMenuProvider = { [weak pv] in
                guard let tabID = pv?.pane.activeTab?.id else { return nil }
                return RuleEngine.shared.profileMenu(tabID: tabID)
            }
        }
    }

    /// Rebuild the split container and fade the freshly created pane in instead
    /// of having it pop into existence. Every pane-creation path goes through
    /// this so the update + fade pairing can't be forgotten at a new call site.
    func updateSplits(_ tree: SplitTree, fadingIn newPaneID: UUID) {
        splitContainer.update(tree: tree)
        guard let pv = paneViews[newPaneID] else { return }
        pv.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pv.animator().alphaValue = 1
        }
    }

    func splitActivePane(direction: SplitTree.SplitDirection) {
        splitActivePane(toward: direction == .horizontal ? .right : .down)
    }

    /// Split the active pane, placing the new pane on `edge`; returns its ID.
    @discardableResult
    func splitActivePane(toward edge: PaneDirection) -> UUID? {
        guard let workspace = activeWorkspace else { return nil }
        return splitPane(workspace.activePaneID, in: workspace, toward: edge)
    }

    /// Splits any pane of this window. `focus: false` leaves focus where it is;
    /// `command` is typed into the new pane's shell as it starts. In a background
    /// workspace only the model changes; its views are built on activation.
    @discardableResult
    func splitPane(
        _ oldPaneID: UUID, in workspace: Workspace, toward edge: PaneDirection,
        focus: Bool = true, cwd: String? = nil, command: String? = nil
    ) -> UUID? {
        // tmux owns the layout of its windows: ask it, and its layout change adds the pane.
        if let tmux = TmuxControlClient.owning(workspace: workspace.id) {
            tmux.split(pane: oldPaneID, toward: edge)
            return nil
        }
        let isVisible = workspace === activeWorkspace
        booLog(.debug, .sidebar, "splitting pane=\(oldPaneID.uuidString.prefix(8)) edge=\(edge)")
        if isVisible { window?.makeFirstResponder(nil) }

        guard let newID = workspace.splitPane(oldPaneID, toward: edge, cwd: cwd) else {
            booLog(.debug, .sidebar, "splitActivePane: pane \(oldPaneID.uuidString.prefix(8)) not found — no-op")
            return nil
        }
        booLog(.debug, .sidebar, "created pane=\(newID.uuidString.prefix(8)) from=\(oldPaneID.uuidString.prefix(8))")
        // Inherit parent tab's plugin state so sidebar stays consistent
        if let newPane = workspace.pane(for: newID),
            let newTab = newPane.activeTab
        {
            if let oldTab = workspace.pane(for: oldPaneID)?.activeTab {
                newPane.updatePluginState(
                    at: newPane.activeTabIndex,
                    expanded: oldTab.state.expandedPluginIDs,
                    sidebarSectionHeights: oldTab.state.sidebarSectionHeights,
                    sidebarScrollOffsets: remapSidebarScrollOffsets(
                        oldTab.state.sidebarScrollOffsets,
                        from: oldTab.id,
                        to: newTab.id
                    ),
                    sidebarSectionOrder: oldTab.state.sidebarSectionOrder,
                    selectedPluginTabID: oldTab.state.selectedPluginTabID)
            } else {
                newPane.updatePluginState(
                    at: newPane.activeTabIndex,
                    expanded: expandedPluginIDs,
                    sidebarSectionHeights: savedSidebarHeights,
                    sidebarScrollOffsets: remapSidebarScrollOffsets(
                        savedSidebarScrollOffsets,
                        from: bridge.state.tabID,
                        to: newTab.id
                    ),
                    sidebarSectionOrder: savedSidebarSectionOrder,
                    selectedPluginTabID: activePluginTabID)
            }
        }
        if let command, let newTab = workspace.pane(for: newID)?.activeTab {
            GhosttyView.pendingLaunch[newTab.id] = LaunchSpec(command: command)
        }
        if focus { workspace.activePaneID = newID }
        guard isVisible else {
            saveSession()
            return newID
        }
        updateSplits(workspace.splitTree, fadingIn: newID)
        saveSession()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Reattach the original pane's session to its (rebuilt) view
            if let oldPV = self.paneViews[oldPaneID] {
                oldPV.startActiveSession()
            }
            // Start the new pane's session
            if let newPV = self.paneViews[newID] {
                newPV.startActiveSession()
            }
            // Refresh all Ghostty surfaces after layout settles
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            self.runPluginCycle(reason: .focusChanged)
            // Focus after layout and plugin cycle complete so nothing steals the responder
            DispatchQueue.main.async { [weak self] in
                guard let self, let pv = self.paneViews[workspace.activePaneID] else { return }
                pv.focusActiveView()
            }
        }
        refreshStatusBar()
        return newID
    }

    @objc func closePaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let paneID = workspace.activePaneID
        booLog(
            .debug, .terminal, "closing pane=\(paneID.uuidString.prefix(8)) remainingPanes=\(workspace.panes.count - 1)"
        )
        if workspace.panes.count > 1, let pane = workspace.pane(for: paneID) {
            notifyTerminalClosed(for: pane.tabs)
        }

        // Clear the previous-tab tracker so the stale bridge state
        // (which still holds the closed pane's title/cwd) is not
        // synced onto the surviving pane's tab when it gains focus.
        previousFocusedTabID = nil

        // Remove the closed pane's view from cache
        bridge.monitor.untrack(paneID: paneID)
        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.stopAll()

        if workspace.closePane(paneID) {
            let validIDs = Set(workspace.splitTree.leafIDs)

            for id in paneViews.keys where !validIDs.contains(id) {
                paneViews.removeValue(forKey: id)
            }

            splitContainer.update(tree: workspace.displayedTree)
            saveSession()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeWorkspace != nil else { return }
                for id in validIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                self.refreshAllSurfaces()
                self.syncCoordinatorPaneViews()
                self.updatePaneCloseButtons()
                self.runPluginCycle(reason: .focusChanged)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let ws = self.activeWorkspace,
                        let pv = self.paneViews[ws.activePaneID]
                    else { return }
                    pv.focusActiveView()
                }
            }
        } else {
            toolbarDidCloseWorkspace(at: appState.activeWorkspaceIndex)
        }
    }

    @objc func reopenTabAction(_ sender: Any?) {
        guard let item = undoStack.popLast(), let workspace = activeWorkspace else { return }
        if openTmuxWindow(in: workspace) { return }

        switch item {
        case .tab(let paneID, let cwd, _):
            let targetPaneID = workspace.pane(for: paneID) != nil ? paneID : workspace.activePaneID
            if let pv = paneViews[targetPaneID] {
                pv.addNewTab(workingDirectory: cwd)
            }

        case .pane(let siblingID, let cwd, let direction):
            // Re-split the sibling pane (or active pane if sibling is gone)
            let targetID = workspace.pane(for: siblingID) != nil ? siblingID : workspace.activePaneID
            window?.makeFirstResponder(nil)

            guard let newID = workspace.splitPane(targetID, direction: direction) else {
                booLog(
                    .debug,
                    .terminal,
                    "undoCloseItem: splitPane returned nil for targetID \(targetID.uuidString.prefix(8)) — skipped"
                )
                break
            }
            // Override the new pane's tab to use the closed pane's cwd
            if let pane = workspace.pane(for: newID) {
                pane.stopAll()
                _ = pane.addTab(workingDirectory: cwd)
            }
            workspace.activePaneID = newID
            splitContainer.update(tree: workspace.displayedTree)
            saveSession()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Reattach all panes
                for id in workspace.splitTree.leafIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                self.updatePaneCloseButtons()
                DispatchQueue.main.async { [weak self] in
                    guard let self, let pv = self.paneViews[newID] else { return }
                    pv.focusActiveView()
                }
            }
        }
        refreshStatusBar()
    }

    func pushUndo(_ item: ClosedItem) {
        undoStack.append(item)
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    /// Find the split direction of the parent split containing the given leaf.
    func findSplitDirection(for leafID: UUID, in tree: SplitTree) -> SplitTree.SplitDirection? {
        switch tree {
        case .leaf:
            return nil
        case .split(let direction, let first, let second, _):
            if first.leafIDs.contains(leafID) || second.leafIDs.contains(leafID) {
                return direction
            }
            return findSplitDirection(for: leafID, in: first) ?? findSplitDirection(for: leafID, in: second)
        }
    }

    /// Find the sibling leaf ID for a given leaf in the split tree.
    func findSiblingID(for leafID: UUID, in tree: SplitTree) -> UUID? {
        switch tree {
        case .leaf:
            return nil
        case .split(_, let first, let second, _):
            if case .leaf(let id) = first, id == leafID {
                return second.leafIDs.first
            }
            if case .leaf(let id) = second, id == leafID {
                return first.leafIDs.first
            }
            return findSiblingID(for: leafID, in: first) ?? findSiblingID(for: leafID, in: second)
        }
    }

    /// Sync the coordinator's paneViews with the current workspace.
    func syncCoordinatorPaneViews() {
        tabDragCoordinator.paneViews = paneViews
    }

    @objc func smartCloseAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: workspace.activePaneID),
            let pv = paneViews[workspace.activePaneID]
        else { return }

        if pane.tabs.count > 1 {
            closeTabAfterConfirmation(
                paneID: workspace.activePaneID,
                tabIndex: pane.activeTabIndex
            ) { [weak self, weak pv] in
                guard let self, let pv else { return }
                let item = ClosedItem.tab(
                    paneID: workspace.activePaneID,
                    workingDirectory: pane.activeTab?.workingDirectory ?? workspace.folderPath,
                    index: pane.activeTabIndex
                )
                self.pushUndo(item)
                if let tab = pane.activeTab {
                    self.notifyTerminalClosed(for: tab.id)
                }
                pv.closeTab(at: pane.activeTabIndex)
                self.refreshStatusBar()
                self.saveSession()
            }
        } else if workspace.panes.count > 1 {
            closeTabAfterConfirmation(paneID: workspace.activePaneID, tabIndex: pane.activeTabIndex) { [weak self] in
                guard let self else { return }
                let cwd = pane.activeTab?.workingDirectory ?? workspace.folderPath
                let direction = self.findSplitDirection(for: workspace.activePaneID, in: workspace.splitTree)
                let siblingID = self.findSiblingID(for: workspace.activePaneID, in: workspace.splitTree)
                let item = ClosedItem.pane(
                    siblingPaneID: siblingID ?? workspace.activePaneID,
                    workingDirectory: cwd,
                    direction: direction ?? .horizontal
                )
                self.pushUndo(item)
                self.closePaneAction(nil)
            }
        } else if appState.workspaces.count > 1 {
            if let location = unsavedEditorLocation(workspaceIndex: appState.activeWorkspaceIndex) {
                confirmUnsavedEditorClose(location) { [weak self] in
                    guard let self else { return }
                    self.presentCloseWorkspaceAlert(at: self.appState.activeWorkspaceIndex)
                }
            } else {
                toolbarDidCloseWorkspace(at: appState.activeWorkspaceIndex)
            }
        } else {
            closeTabAfterConfirmation(paneID: workspace.activePaneID, tabIndex: pane.activeTabIndex) { [weak self] in
                guard let self else { return }
                if let tab = pane.activeTab {
                    self.notifyTerminalClosed(for: tab.id)
                }
                self.allowNextWindowClose = true
                self.window?.close()
            }
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        WindowManager.shared.windowDidBecomeMain(self)
        // The main menu is app-wide but plugin items target one controller, so the
        // window becoming main takes the menu over and refreshes the shared plugin
        // context (AppStore.shared) with its own state.
        guard WindowManager.shared.menuOwner !== self else { return }
        setupMenuItems()
        rebuildPluginsMenu()
        runPluginCycle(reason: .focusChanged)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextWindowClose {
            allowNextWindowClose = false
            return true
        }

        if let location = unsavedEditorLocation() {
            confirmUnsavedEditorClose(location) { [weak self] in
                self?.allowNextWindowClose = true
                sender.close()
            }
            return false
        }

        return true
    }
}
