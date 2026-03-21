import Cocoa

// MARK: - PaneViewDelegate

extension MainWindowController: PaneViewDelegate {
    func paneView(_ paneView: PaneView, didFocus paneID: UUID) {
        guard let workspace = activeWorkspace else { return }
        workspace.activePaneID = paneID
        let tab = workspace.pane(for: paneID)?.activeTab
        let cwd = tab?.workingDirectory ?? workspace.folderPath

        NSLog(
            "[MWC] didFocus: paneID=\(paneID), tabTitle=\(tab?.title ?? "nil"), cwd=\(cwd), tabRemote=\(String(describing: tab?.remoteSession)), tabRemoteCwd=\(String(describing: tab?.remoteWorkingDirectory))"
        )

        // Restore the full bridge + plugin state from the tab model via coordinator.
        if let tab = tab {
            coordinator.activateTab(tab, paneID: paneID) { [weak self] tabID in
                self?.findPaneContainingTab(tabID)
            }
        } else {
            bridge.handleFocus(paneID: paneID, workingDirectory: cwd)
        }
        runPluginCycle(reason: .focusChanged)
    }

    func paneView(_ paneView: PaneView, didChangeDirectory path: String, paneID: UUID) {
        guard let workspace = activeWorkspace, workspace.activePaneID == paneID else { return }
        bridge.handleDirectoryChange(path: path, paneID: paneID)
        // Coordinator syncs bridge state → TabState
        if let pane = workspace.pane(for: paneID) {
            coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
        }
        syncRemoteSidebarState()
    }

    func paneView(_ paneView: PaneView, titleChanged title: String, paneID: UUID) {
        guard let workspace = activeWorkspace else { return }
        bridge.handleTitleChange(title: title, paneID: paneID)
        guard workspace.activePaneID == paneID else { return }
        if let pane = workspace.pane(for: paneID) {
            coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
        }
        syncRemoteSidebarState()
    }

    func paneView(_ paneView: PaneView, foregroundProcessChanged name: String, paneID: UUID) {
        // Handled by bridge via titleChanged
    }

    func paneView(
        _ paneView: PaneView, remoteStateChanged session: RemoteSessionType?, remoteCwd: String?, paneID: UUID
    ) {
        // Handled by bridge via heuristic detection
    }

    func paneView(_ paneView: PaneView, remoteConnectionFailed session: RemoteSessionType, paneID: UUID) {
        // Handled by bridge via heuristic detection
    }

    func paneView(_ paneView: PaneView, directoryListing path: String, output: String, paneID: UUID) {
        bridge.handleDirectoryListing(path: path, output: output, paneID: paneID)
    }

    func paneView(_ paneView: PaneView, shellPIDDiscovered pid: pid_t, paneID: UUID) {
        bridge.monitor.track(paneID: paneID, shellPID: pid)
    }

    func paneView(_ paneView: PaneView, didRequestCloseTab index: Int, paneID: UUID) {
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: paneID),
            let pv = paneViews[paneID]
        else { return }

        if pane.tabs.count > 1 {
            // Confirm before closing
            guard let window = window else { return }
            let alert = NSAlert()
            alert.messageText = "Close this tab?"
            alert.informativeText = "This will end the terminal session in this tab."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let item = ClosedItem.tab(
                    paneID: paneID,
                    workingDirectory: pane.tabs[index].workingDirectory,
                    index: index
                )
                self?.pushUndo(item)
                pv.closeTab(at: index)
                self?.refreshStatusBar()
            }
        } else {
            // Last tab — use smartClose to handle pane/workspace cascading
            smartCloseAction(nil)
        }
    }

    func paneView(_ paneView: PaneView, sessionEnded paneID: UUID) {
        guard let workspace = activeWorkspace else { return }

        if let pane = workspace.pane(for: paneID) {
            pane.updateRemoteSession(at: pane.activeTabIndex, nil)
        }

        bridge.monitor.untrack(paneID: paneID)
        bridge.handleProcessExit(paneID: paneID)

        // Focus this pane first so smartClose acts on the right one
        if workspace.activePaneID != paneID {
            workspace.activePaneID = paneID
        }
        smartCloseAction(nil)
    }
}

// MARK: - Pane Management

extension MainWindowController {
    /// Update all pane views' close-button visibility based on total pane count.
    func updatePaneCloseButtons() {
        let multiPane = activeWorkspace.map { $0.panes.count > 1 } ?? false
        for (_, pv) in paneViews {
            pv.showCloseOnSingleTab = multiPane
            pv.needsDisplay = true
        }
    }

    func splitActivePane(direction: SplitTree.SplitDirection) {
        guard let workspace = activeWorkspace else { return }
        let oldPaneID = workspace.activePaneID
        window?.makeFirstResponder(nil)

        let newID = workspace.splitPane(oldPaneID, direction: direction)
        // Inherit parent tab's plugin state so sidebar stays consistent
        if let newPane = workspace.pane(for: newID),
            newPane.activeTab != nil
        {
            if let oldTab = workspace.pane(for: oldPaneID)?.activeTab {
                newPane.updatePluginState(
                    at: newPane.activeTabIndex,
                    open: oldTab.state.openPluginIDs,
                    expanded: oldTab.state.expandedPluginIDs)
            } else {
                newPane.updatePluginState(
                    at: newPane.activeTabIndex,
                    open: openPluginIDs,
                    expanded: expandedPluginIDs)
            }
        }
        // Focus the newly created pane
        workspace.activePaneID = newID
        splitContainer.update(tree: workspace.splitTree)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Reattach the original pane's session to its (rebuilt) view
            if let oldPV = self.paneViews[oldPaneID] {
                oldPV.startActiveSession()
            }
            // Start the new pane's session and focus it
            if let newPV = self.paneViews[newID] {
                newPV.startActiveSession()
                self.window?.makeFirstResponder(newPV.currentTerminalView)
            }
            // Refresh all Ghostty surfaces after layout settles
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
        refreshStatusBar()
    }

    @objc func closePaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let paneID = workspace.activePaneID

        // Remove the closed pane's view from cache
        bridge.monitor.untrack(paneID: paneID)
        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.stopAll()

        if workspace.closePane(paneID) {
            let validIDs = Set(workspace.splitTree.leafIDs)

            for id in paneViews.keys where !validIDs.contains(id) {
                paneViews.removeValue(forKey: id)
            }

            splitContainer.update(tree: workspace.splitTree)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let ws = self.activeWorkspace else { return }
                for id in validIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                if let pv = self.paneViews[ws.activePaneID] {
                    self.window?.makeFirstResponder(pv.currentTerminalView)
                }
                self.refreshAllSurfaces()
                self.syncCoordinatorPaneViews()
                self.updatePaneCloseButtons()
                self.runPluginCycle(reason: .focusChanged)
            }
        } else {
            toolbarDidCloseWorkspace(at: appState.activeWorkspaceIndex)
        }
    }

    @objc func reopenTabAction(_ sender: Any?) {
        guard let item = undoStack.popLast(), let workspace = activeWorkspace else { return }

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

            let newID = workspace.splitPane(targetID, direction: direction)
            // Override the new pane's tab to use the closed pane's cwd
            if let pane = workspace.pane(for: newID) {
                pane.stopAll()
                _ = pane.addTab(workingDirectory: cwd)
            }
            workspace.activePaneID = newID
            splitContainer.update(tree: workspace.splitTree)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Reattach all panes
                for id in workspace.splitTree.leafIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                if let pv = self.paneViews[newID] {
                    pv.startActiveSession()
                    self.window?.makeFirstResponder(pv.currentTerminalView)
                }
                self.updatePaneCloseButtons()
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

    // MARK: - Cross-Pane Tab Drag & Drop

    func handleTabDrop(source: PaneView, tabIndex: Int, dest: PaneView, zone: TabDropZone) {
        guard activeWorkspace != nil else { return }

        switch zone {
        case .tabBarInsert(let insertIdx):
            moveTabBetweenPanes(source: source, tabIndex: tabIndex, dest: dest, insertAt: insertIdx)
            // For tab bar moves, close empty source synchronously — no split rebuild involved
            if source.pane.tabs.isEmpty {
                closeEmptyPane(source.paneID)
            }
        case .left:
            splitPaneWithTab(
                source: source, tabIndex: tabIndex, target: dest,
                direction: .horizontal, insertBefore: true)
        case .right:
            splitPaneWithTab(
                source: source, tabIndex: tabIndex, target: dest,
                direction: .horizontal, insertBefore: false)
        case .top:
            splitPaneWithTab(
                source: source, tabIndex: tabIndex, target: dest,
                direction: .vertical, insertBefore: true)
        case .bottom:
            splitPaneWithTab(
                source: source, tabIndex: tabIndex, target: dest,
                direction: .vertical, insertBefore: false)
        }

        syncCoordinatorPaneViews()
    }

    private func moveTabBetweenPanes(source: PaneView, tabIndex: Int, dest: PaneView, insertAt: Int) {
        guard let workspace = activeWorkspace else { return }
        let sourcePane = source.pane
        let destPane = dest.pane

        // Extract tab + view from source
        guard let tab = sourcePane.extractTab(at: tabIndex) else { return }
        guard let gv = source.extractGhosttyView(for: tab.id) else { return }

        // If source still has tabs, show the now-active one
        if !sourcePane.tabs.isEmpty {
            source.startActiveSession()
            source.layoutTerminalView()
            source.needsDisplay = true
        }

        // Insert into destination at the specified index.
        // insertTab sets activeTabIndex = insertIndex, so activateTab's
        // early-return guard would skip. Use forceActivateTab instead.
        let insertIndex = min(insertAt, destPane.tabs.count)
        destPane.insertTab(tab, at: insertIndex)
        dest.insertGhosttyView(gv, for: tab.id)
        dest.forceActivateTab(insertIndex)

        workspace.activePaneID = dest.paneID
        window?.makeFirstResponder(dest.currentTerminalView)
    }

    private func splitPaneWithTab(
        source: PaneView, tabIndex: Int, target: PaneView,
        direction: SplitTree.SplitDirection, insertBefore: Bool
    ) {
        guard let workspace = activeWorkspace else { return }
        let sourcePane = source.pane
        let sourcePaneID = source.paneID
        let sourceIsEmpty: Bool

        // 1. Extract tab + view from source (before any tree changes)
        guard let tab = sourcePane.extractTab(at: tabIndex) else { return }
        guard let gv = source.extractGhosttyView(for: tab.id) else { return }
        sourceIsEmpty = sourcePane.tabs.isEmpty

        // 2. Split the target pane — creates new leaf in the tree
        window?.makeFirstResponder(nil)
        let newPaneID = workspace.splitPane(target.paneID, direction: direction)

        // For left/top drops, swap children so new pane appears first
        if insertBefore {
            workspace.splitTree = workspace.splitTree.swappingChildrenAtParent(of: newPaneID)
        }

        // Replace the new pane's default tab with the dragged tab
        if let newPane = workspace.pane(for: newPaneID) {
            newPane.stopAll()
            newPane.insertTab(tab, at: 0)
        }

        // 3. If source is now empty, remove it from the tree in the same pass
        if sourceIsEmpty {
            let closedPV = paneViews.removeValue(forKey: sourcePaneID)
            closedPV?.stopAll()
            _ = workspace.closePane(sourcePaneID)
            // Clean up stale pane views
            let validIDs = Set(workspace.splitTree.leafIDs)
            for id in paneViews.keys where !validIDs.contains(id) {
                paneViews.removeValue(forKey: id)
            }
        }

        workspace.activePaneID = newPaneID

        // 4. Single tree rebuild with all changes applied
        splitContainer.update(tree: workspace.splitTree)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Insert the transferred GhosttyView BEFORE starting sessions,
            // so startActiveSession finds it in the cache instead of creating
            // a new empty terminal.
            if let newPV = self.paneViews[newPaneID] {
                newPV.insertGhosttyView(gv, for: tab.id)
            }

            // Restart all pane sessions
            for id in workspace.splitTree.leafIDs {
                if let pv = self.paneViews[id] {
                    pv.tabDragCoordinator = self.tabDragCoordinator
                    pv.startActiveSession()
                }
            }

            if let newPV = self.paneViews[newPaneID] {
                self.window?.makeFirstResponder(newPV.currentTerminalView)
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }

    /// Close an empty pane after its last tab was dragged out.
    private func closeEmptyPane(_ paneID: UUID) {
        guard let workspace = activeWorkspace else { return }

        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.stopAll()

        guard workspace.closePane(paneID) else { return }

        let validIDs = Set(workspace.splitTree.leafIDs)
        for id in paneViews.keys where !validIDs.contains(id) {
            paneViews.removeValue(forKey: id)
        }

        splitContainer.update(tree: workspace.splitTree)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let ws = self.activeWorkspace else { return }
            for id in validIDs {
                if let pv = self.paneViews[id] {
                    pv.tabDragCoordinator = self.tabDragCoordinator
                    pv.startActiveSession()
                }
            }
            if let pv = self.paneViews[ws.activePaneID] {
                self.window?.makeFirstResponder(pv.currentTerminalView)
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }

    @objc func smartCloseAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: workspace.activePaneID),
            let pv = paneViews[workspace.activePaneID]
        else { return }

        if pane.tabs.count > 1 {
            // Multiple tabs: close the active tab (undoable)
            let item = ClosedItem.tab(
                paneID: workspace.activePaneID,
                workingDirectory: pane.activeTab?.workingDirectory ?? workspace.folderPath,
                index: pane.activeTabIndex
            )
            pushUndo(item)
            pv.closeTab(at: pane.activeTabIndex)
            refreshStatusBar()
        } else if workspace.panes.count > 1 {
            // Multiple panes but single tab: close the pane (undoable)
            let cwd = pane.activeTab?.workingDirectory ?? workspace.folderPath
            // Determine split direction from the tree
            let direction = findSplitDirection(for: workspace.activePaneID, in: workspace.splitTree)
            let siblingID = findSiblingID(for: workspace.activePaneID, in: workspace.splitTree)
            let item = ClosedItem.pane(
                siblingPaneID: siblingID ?? workspace.activePaneID,
                workingDirectory: cwd,
                direction: direction ?? .horizontal
            )
            pushUndo(item)
            closePaneAction(nil)
        } else if appState.workspaces.count > 1 {
            // Multiple workspaces: close this workspace
            toolbarDidCloseWorkspace(at: appState.activeWorkspaceIndex)
        } else {
            // Last tab, last pane, last workspace: just close
            window?.close()
        }
    }
}
