import Cocoa

// MARK: - PaneViewDelegate

extension MainWindowController: PaneViewDelegate {
    func paneView(_ paneView: PaneView, didFocus paneID: UUID) {
        guard let workspace = activeWorkspace else { return }
        if paneID != workspace.activePaneID {
            savePluginStateForActiveTab()
        }

        // Debounce: skip if the same pane re-focused within 250ms.
        // Sidebar rebuilds can steal first responder from GhosttyView, causing
        // Ghostty to re-fire the focus callback and creating a feedback loop.
        let now = DispatchTime.now().uptimeNanoseconds
        if paneID == lastFocusedPaneID,
            now - lastFocusTimestamp < 250_000_000
        {
            return
        }
        lastFocusedPaneID = paneID
        lastFocusTimestamp = now

        workspace.activePaneID = paneID
        let tab = workspace.pane(for: paneID)?.activeTab
        let cwd = tab?.workingDirectory ?? workspace.folderPath

        NSLog(
            "[MWC] didFocus: paneID=\(paneID), tabTitle=\(tab?.title ?? "nil"), cwd=\(cwd), tabRemote=\(String(describing: tab?.remoteSession)), tabRemoteCwd=\(String(describing: tab?.remoteWorkingDirectory))"
        )

        debugLog(
            "[Focus] didFocus pane=\(paneID.uuidString.prefix(8)) tab=\(tab?.id.uuidString.prefix(8) ?? "nil") title=\(tab?.title ?? "nil") process=\(tab?.state.foregroundProcess ?? "nil")"
        )

        // Restore the full bridge + plugin state from the tab model via coordinator.
        if let tab = tab {
            coordinator.activateTab(tab, paneID: paneID) { [weak self] tabID in
                self?.findPaneContainingTab(tabID)
            }
            // Sync the restored selected plugin tab back to the controller so
            // rebuildSidebarTabs uses the right tab instead of keeping the stale one.
            // Skip when sidebar global state is on — the sidebar is independent of tabs.
            if !AppSettings.shared.sidebarGlobalState {
                activePluginTabID = coordinator.selectedPluginTabID
            }
        } else {
            bridge.handleFocus(paneID: paneID, workingDirectory: cwd)
        }
        runPluginCycle(reason: .focusChanged)
        if let tabID = workspace.pane(for: paneID)?.activeTab?.id {
            flushPendingImageSend(for: tabID, paneID: paneID)
        }
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

    func paneView(_ paneView: PaneView, shellPIDDiscovered pid: pid_t, paneID: UUID, tabID: UUID?) {
        bridge.monitor.track(paneID: paneID, shellPID: pid, tabID: tabID)
    }

    func paneViewIsOnlyPaneInWorkspace(_ paneView: PaneView) -> Bool {
        guard let ws = appState.workspaces.first(where: { $0.panes[paneView.paneID] != nil }) else { return true }
        return ws.panes.count == 1
    }

    func paneViewWorkspaceNames(_ paneView: PaneView) -> [(index: Int, name: String)] {
        // Return all workspaces except the one this pane belongs to
        guard let currentWS = appState.workspaces.first(where: { $0.panes[paneView.paneID] != nil }) else {
            return []
        }
        return appState.workspaces.enumerated().compactMap { (i, ws) in
            ws.id == currentWS.id ? nil : (index: i, name: ws.displayName)
        }
    }

    func paneView(_ paneView: PaneView, didRequestMoveTab index: Int, toWorkspaceAt workspaceIndex: Int, paneID: UUID) {
        guard workspaceIndex >= 0, workspaceIndex < appState.workspaces.count else { return }
        guard let sourceWorkspace = appState.workspaces.first(where: { $0.panes[paneID] != nil }),
            let sourcePane = sourceWorkspace.pane(for: paneID),
            let pv = workspacePaneViews[sourceWorkspace.id]?[paneID]
        else { return }

        let isLastTabInWorkspace = sourceWorkspace.totalTabCount == 1

        if isLastTabInWorkspace && appState.workspaces.count <= 1 {
            // Only workspace — can't move, nothing to move to
            return
        }

        let destWorkspace = appState.workspaces[workspaceIndex]
        let destPaneID = destWorkspace.activePaneID
        guard let destPane = destWorkspace.pane(for: destPaneID) else { return }

        // Extract the tab and its GhosttyView from the source pane
        guard let tab = sourcePane.extractTab(at: index) else { return }
        let gv = pv.extractGhosttyView(for: tab.id)

        // Restore source view if it still has tabs
        if !sourcePane.tabs.isEmpty {
            pv.startActiveSession()
            pv.layoutTerminalView()
            pv.needsDisplay = true
        }

        // Insert tab into destination workspace's active pane
        let insertIndex = destPane.tabs.count
        destPane.insertTab(tab, at: insertIndex)

        // Cache the GhosttyView in the destination pane view (if it exists)
        if let gv = gv, let destPV = workspacePaneViews[destWorkspace.id]?[destPaneID] {
            destPV.insertGhosttyView(gv, for: tab.id)
        }

        // If source pane is now empty, close it (which may close the workspace)
        if sourcePane.tabs.isEmpty {
            let sourceWasActive = sourceWorkspace.id == activeWorkspace?.id
            if isLastTabInWorkspace {
                // Close the entire workspace
                if let resolvedIndex = appState.workspaces.firstIndex(where: { $0.id == sourceWorkspace.id }) {
                    forceCloseWorkspace(at: resolvedIndex)
                }
            } else {
                // Just close the empty pane
                if sourceWasActive {
                    closeEmptyPane(paneID)
                } else {
                    // Remove from non-active workspace's pane views
                    workspacePaneViews[sourceWorkspace.id]?.removeValue(forKey: paneID)
                    pv.stopAll()
                    _ = sourceWorkspace.closePane(paneID)
                }
            }
        }

        // Switch to destination workspace so user sees where tab landed
        if let destIndex = appState.workspaces.firstIndex(where: { $0.id == destWorkspace.id }) {
            activateWorkspace(destIndex)
            // Activate the moved tab in the destination pane
            if let destPV = paneViews[destPaneID] {
                destPV.forceActivateTab(insertIndex)
                window?.makeFirstResponder(destPV.ghosttyView)
            }
        }

        saveSession()
    }

    func paneView(_ paneView: PaneView, didRequestCloseTab index: Int, paneID: UUID) {
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: paneID),
            let pv = paneViews[paneID]
        else { return }

        guard let window = window else { return }
        let tabID = pane.tabs[index].id
        let isLastTab = pane.tabs.count == 1
        let alert = NSAlert()
        alert.messageText = isLastTab ? "Close this pane?" : "Close this tab?"
        alert.informativeText = "This will end the terminal session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if isLastTab {
                workspace.activePaneID = paneID
                self?.smartCloseAction(nil)
            } else {
                // Re-resolve index — tabs may have changed while alert was shown
                guard let currentIndex = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                let item = ClosedItem.tab(
                    paneID: paneID,
                    workingDirectory: pane.tabs[currentIndex].workingDirectory,
                    index: currentIndex
                )
                self?.pushUndo(item)
                self?.notifyTerminalClosed(for: pane.tabs[currentIndex].id)
                pv.closeTab(at: currentIndex)
                self?.refreshStatusBar()
                self?.saveSession()
            }
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
        debugLog("[Split] splitting pane=\(oldPaneID.uuidString.prefix(8)) direction=\(direction)")
        window?.makeFirstResponder(nil)

        let newID = workspace.splitPane(oldPaneID, direction: direction)
        debugLog("[Split] created pane=\(newID.uuidString.prefix(8)) from=\(oldPaneID.uuidString.prefix(8))")
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
                    selectedPluginTabID: activePluginTabID)
            }
        }
        // Focus the newly created pane
        workspace.activePaneID = newID
        splitContainer.update(tree: workspace.splitTree)
        saveSession()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Reattach the original pane's session to its (rebuilt) view
            if let oldPV = self.paneViews[oldPaneID] {
                oldPV.startActiveSession()
            }
            // Start the new pane's session and focus it
            if let newPV = self.paneViews[newID] {
                newPV.startActiveSession()
                self.window?.makeFirstResponder(newPV.ghosttyView)
            }
            // Refresh all Ghostty surfaces after layout settles
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            self.runPluginCycle(reason: .focusChanged)
        }
        refreshStatusBar()
    }

    @objc func closePaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let paneID = workspace.activePaneID
        debugLog("[Close] closing pane=\(paneID.uuidString.prefix(8)) remainingPanes=\(workspace.panes.count - 1)")
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

            splitContainer.update(tree: workspace.splitTree)
            saveSession()

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let ws = self.activeWorkspace else { return }
                for id in validIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                if let pv = self.paneViews[ws.activePaneID] {
                    self.window?.makeFirstResponder(pv.ghosttyView)
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
            saveSession()

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
                    self.window?.makeFirstResponder(pv.ghosttyView)
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

        // Detect cross-workspace drop: source pane is not in the current workspace's pane views.
        // This happens when the user hovered over a workspace pill mid-drag to switch workspaces.
        let isCrossWorkspace = paneViews[source.paneID] == nil
        if isCrossWorkspace {
            handleCrossWorkspaceTabDrop(source: source, tabIndex: tabIndex, dest: dest, zone: zone)
            syncCoordinatorPaneViews()
            return
        }

        // Same-workspace drop — check if this is the last tab in the workspace.
        // If so, abort: dropping the only tab would leave an empty workspace.
        let sourceWorkspaceTotalTabs = activeWorkspace?.totalTabCount ?? 0
        if sourceWorkspaceTotalTabs == 1 && source.paneID != dest.paneID {
            // Last tab being dragged to a different pane (split zone) within the same workspace —
            // this would leave the source workspace empty. Abort silently.
            return
        }

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

    /// Handle a drop where the source pane belongs to a different (now-inactive) workspace.
    private func handleCrossWorkspaceTabDrop(
        source: PaneView, tabIndex: Int, dest: PaneView, zone: TabDropZone
    ) {
        guard let destWorkspace = activeWorkspace,
            let sourceWorkspace = appState.workspaces.first(where: { $0.panes[source.paneID] != nil })
        else { return }

        let isLastTabInSourceWorkspace = sourceWorkspace.totalTabCount == 1

        if isLastTabInSourceWorkspace {
            // Dropping the only tab out of a workspace — ask user what to do
            guard let window = window else { return }
            let alert = NSAlert()
            alert.messageText = "Move last tab out of \"\(sourceWorkspace.displayName)\"?"
            alert.informativeText =
                "This is the only tab in that workspace. Moving it will close the workspace."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move & Close Workspace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.executeCrossWorkspaceDrop(
                    source: source, tabIndex: tabIndex, dest: dest, zone: zone,
                    sourceWorkspace: sourceWorkspace, destWorkspace: destWorkspace,
                    closeSourceWorkspace: true)
            }
        } else {
            executeCrossWorkspaceDrop(
                source: source, tabIndex: tabIndex, dest: dest, zone: zone,
                sourceWorkspace: sourceWorkspace, destWorkspace: destWorkspace,
                closeSourceWorkspace: false)
        }
    }

    private func executeCrossWorkspaceDrop(
        source: PaneView, tabIndex: Int, dest: PaneView, zone: TabDropZone,
        sourceWorkspace: Workspace, destWorkspace: Workspace,
        closeSourceWorkspace: Bool
    ) {
        let sourcePane = source.pane
        guard let tab = sourcePane.extractTab(at: tabIndex) else { return }
        let gv = source.extractGhosttyView(for: tab.id)

        // Restore source view if still has tabs
        if !sourcePane.tabs.isEmpty {
            source.startActiveSession()
            source.layoutTerminalView()
            source.needsDisplay = true
        }

        // Perform the drop into the destination workspace
        switch zone {
        case .tabBarInsert(let insertIdx):
            let insertIndex = min(insertIdx, dest.pane.tabs.count)
            dest.pane.insertTab(tab, at: insertIndex)
            if let gv = gv { dest.insertGhosttyView(gv, for: tab.id) }
            dest.forceActivateTab(insertIndex)
            destWorkspace.activePaneID = dest.paneID
            window?.makeFirstResponder(dest.ghosttyView)
        case .left, .right, .top, .bottom:
            let direction: SplitTree.SplitDirection = (zone == .left || zone == .right) ? .horizontal : .vertical
            let insertBefore = (zone == .left || zone == .top)
            let newPaneID = destWorkspace.splitPane(dest.paneID, direction: direction)
            if insertBefore {
                destWorkspace.splitTree = destWorkspace.splitTree.swappingChildrenAtParent(of: newPaneID)
            }
            if let newPane = destWorkspace.pane(for: newPaneID) {
                newPane.stopAll()
                newPane.insertTab(tab, at: 0)
            }
            destWorkspace.activePaneID = newPaneID
            splitContainer.update(tree: destWorkspace.splitTree)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let newPV = self.paneViews[newPaneID] {
                    if let gv = gv { newPV.insertGhosttyView(gv, for: tab.id) }
                    newPV.tabDragCoordinator = self.tabDragCoordinator
                    newPV.startActiveSession()
                    self.window?.makeFirstResponder(newPV.ghosttyView)
                }
                for id in destWorkspace.splitTree.leafIDs where id != newPaneID {
                    self.paneViews[id]?.startActiveSession()
                }
                self.refreshAllSurfaces()
                self.syncCoordinatorPaneViews()
                self.updatePaneCloseButtons()
            }
        }

        // Close source pane / workspace
        if closeSourceWorkspace {
            if let idx = appState.workspaces.firstIndex(where: { $0.id == sourceWorkspace.id }) {
                // Notify terminals then destroy views — but don't switch workspace (we're already on dest)
                for pane in sourceWorkspace.panes.values {
                    notifyTerminalClosed(for: pane.tabs)
                }
                if let views = workspacePaneViews.removeValue(forKey: sourceWorkspace.id) {
                    for (_, pv) in views { pv.stopAll() }
                }
                appState.removeWorkspace(at: idx)
                refreshToolbar()
                saveSession()
            }
        } else if sourcePane.tabs.isEmpty {
            // Source pane is now empty — close just the pane in the source workspace
            workspacePaneViews[sourceWorkspace.id]?.removeValue(forKey: source.paneID)
            source.stopAll()
            _ = sourceWorkspace.closePane(source.paneID)
            saveSession()
        }

        saveSession()
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
        window?.makeFirstResponder(dest.ghosttyView)
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
        saveSession()

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
                self.window?.makeFirstResponder(newPV.ghosttyView)
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }

    /// Close an empty pane after its last tab was dragged out.
    private func closeEmptyPane(_ paneID: UUID) {
        guard let workspace = activeWorkspace else { return }

        previousFocusedTabID = nil

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
                self.window?.makeFirstResponder(pv.ghosttyView)
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
            if let tab = pane.activeTab {
                notifyTerminalClosed(for: tab.id)
            }
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
            if let tab = pane.activeTab {
                notifyTerminalClosed(for: tab.id)
            }
            window?.close()
        }
    }
}
