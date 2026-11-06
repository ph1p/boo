import Cocoa

// MARK: - Cross-Pane Tab Drag & Drop

extension MainWindowController {
    func handleTabDrop(source: PaneView, tabIndex: Int, dest: PaneView, zone: TabDropZone) {
        guard activeWorkspace != nil else { return }
        // tmux owns which pane a tmux tab lives in: ask tmux to move it.
        if source.paneID != dest.paneID, source.pane.tmuxOwned || dest.pane.tmuxOwned {
            tmuxTabDrop(source: source.paneID, dest: dest.paneID, zone: zone)
            return
        }

        // Dropped on a pane of another window: the tab moves there.
        if let target = WindowManager.shared.controller(showing: dest), target !== self {
            moveTab(source: source, tabIndex: tabIndex, toWindow: target, dest: dest, zone: zone)
            return
        }

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
        case .center:
            moveTabBetweenPanes(source: source, tabIndex: tabIndex, dest: dest, insertAt: dest.pane.tabs.count)
            if source.pane.tabs.isEmpty {
                closeEmptyPane(source.paneID)
            }
        case .swapPanes:
            guard let workspace = activeWorkspace else { break }
            swapPanes(source.paneID, dest.paneID, in: workspace)
        case .tabBarGroup:
            break  // same-pane only, done by the coordinator
        case .left, .right, .top, .bottom, .workspaceEdge:
            guard let placement = zone.splitPlacement else { break }
            splitPaneWithTab(
                source: source, tabIndex: tabIndex, target: dest,
                edge: placement.edge, wholeWorkspace: placement.wholeWorkspace)
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
        let gv = tab.contentType == .terminal ? source.extractGhosttyView(for: tab.id) : nil
        let cv = tab.contentType != .terminal ? source.extractContentView(for: tab.id) : nil

        // Restore source view if still has tabs
        if !sourcePane.tabs.isEmpty {
            source.startActiveSession()
            source.layoutTerminalView()
            source.needsDisplay = true
        }

        // Perform the drop into the destination workspace
        insertDroppedTab(tab, ghosttyView: gv, contentView: cv, into: dest, zone: zone, workspace: destWorkspace)

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
                destroyWorkspace(at: idx)
                refreshToolbar()
            }
        } else if sourcePane.tabs.isEmpty {
            // Source pane is now empty — close just the pane in the source workspace
            workspacePaneViews[sourceWorkspace.id]?.removeValue(forKey: source.paneID)
            source.stopAll()
            _ = sourceWorkspace.closePane(source.paneID)
        }

        saveSession()
    }

    /// Put a tab extracted from another pane (this window or another one) into
    /// `dest`: its tab bar, or a new split next to it. The transferred view is
    /// inserted before the session starts, so the live terminal is reused.
    /// Returns the pane that received the tab.
    @discardableResult
    func insertDroppedTab(
        _ tab: Pane.Tab, ghosttyView gv: GhosttyView?, contentView cv: ContentViewProtocol?,
        into dest: PaneView, zone: TabDropZone, workspace destWorkspace: Workspace
    ) -> UUID {
        let placement = zone.splitPlacement
        if let placement,
            let newPaneID = destWorkspace.splitPane(
                dest.paneID, toward: placement.edge, wholeWorkspace: placement.wholeWorkspace)
        {
            if let newPane = destWorkspace.pane(for: newPaneID) {
                newPane.stopAll()
                newPane.insertTab(tab, at: 0)
            }
            destWorkspace.activePaneID = newPaneID
            updateSplits(destWorkspace.splitTree, fadingIn: newPaneID)
            DispatchQueue.main.async { [weak self, tab, gv, cv] in
                guard let self else { return }
                if let newPV = self.paneViews[newPaneID] {
                    if let gv = gv {
                        newPV.insertGhosttyView(gv, for: tab.id)
                    } else if let cv = cv {
                        newPV.insertContentView(cv, for: tab.id)
                    }
                    newPV.tabDragCoordinator = self.tabDragCoordinator
                    newPV.startActiveSession()
                }
                for id in destWorkspace.splitTree.leafIDs where id != newPaneID {
                    self.paneViews[id]?.startActiveSession()
                }
                self.refreshAllSurfaces()
                self.syncCoordinatorPaneViews()
                self.updatePaneCloseButtons()
                DispatchQueue.main.async { [weak self] in
                    guard let self, let newPV = self.paneViews[newPaneID] else { return }
                    newPV.focusActiveView()
                }
            }
            return newPaneID
        }
        if placement != nil {
            booLog(.debug, .terminal, "insertDroppedTab: splitPane returned nil — appending to tab bar")
        }

        // Tab bar or center drop (or a split that could not be made): the tab
        // must not get lost, so it always lands in `dest`.
        var insertIdx = dest.pane.tabs.count
        if case .tabBarInsert(let idx) = zone { insertIdx = min(idx, insertIdx) }
        dest.pane.insertTab(tab, at: insertIdx)
        if let gv = gv {
            dest.insertGhosttyView(gv, for: tab.id)
        } else if let cv = cv {
            dest.insertContentView(cv, for: tab.id)
        }
        dest.forceActivateTab(insertIdx)
        destWorkspace.activePaneID = dest.paneID
        if tab.contentType == .terminal {
            window?.makeFirstResponder(dest.ghosttyView)
        } else {
            window?.makeFirstResponder(dest.activeContentView)
        }
        return dest.paneID
    }

    private func moveTabBetweenPanes(source: PaneView, tabIndex: Int, dest: PaneView, insertAt: Int) {
        guard let workspace = activeWorkspace else { return }
        let sourcePane = source.pane
        let destPane = dest.pane

        // Extract tab + view from source
        guard let tab = sourcePane.extractTab(at: tabIndex) else { return }
        let gv = tab.contentType == .terminal ? source.extractGhosttyView(for: tab.id) : nil
        let cv = tab.contentType != .terminal ? source.extractContentView(for: tab.id) : nil

        // Ensure we have a view to transfer
        guard gv != nil || cv != nil else {
            return
        }

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
        if let gv = gv {
            dest.insertGhosttyView(gv, for: tab.id)
        } else if let cv = cv {
            dest.insertContentView(cv, for: tab.id)
        }
        dest.forceActivateTab(insertIndex)

        workspace.activePaneID = dest.paneID
        if tab.contentType == .terminal {
            window?.makeFirstResponder(dest.ghosttyView)
        } else {
            window?.makeFirstResponder(dest.activeContentView)
        }
    }

    private func splitPaneWithTab(
        source: PaneView, tabIndex: Int, target: PaneView,
        edge: PaneDirection, wholeWorkspace: Bool
    ) {
        guard let workspace = activeWorkspace else { return }
        let sourcePane = source.pane
        let sourcePaneID = source.paneID
        let sourceIsEmpty: Bool

        // 1. Extract tab + view from source (before any tree changes)
        guard let tab = sourcePane.extractTab(at: tabIndex) else { return }
        let gv = tab.contentType == .terminal ? source.extractGhosttyView(for: tab.id) : nil
        let cv = tab.contentType != .terminal ? source.extractContentView(for: tab.id) : nil

        // Ensure we have a view to transfer
        guard gv != nil || cv != nil else { return }
        sourceIsEmpty = sourcePane.tabs.isEmpty

        // 2. Split the target pane — creates new leaf in the tree
        window?.makeFirstResponder(nil)
        guard let newPaneID = workspace.splitPane(target.paneID, toward: edge, wholeWorkspace: wholeWorkspace) else {
            booLog(
                .debug,
                .terminal,
                "splitPaneWithTab: splitPane returned nil for target \(target.paneID.uuidString.prefix(8)) — restoring extracted tab"
            )
            sourcePane.insertTab(tab, at: tabIndex)
            return
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
        updateSplits(workspace.splitTree, fadingIn: newPaneID)
        saveSession()

        DispatchQueue.main.async { [weak self, tab, gv, cv] in
            guard let self else { return }

            // Insert the transferred view BEFORE starting sessions,
            // so startActiveSession finds it in the cache instead of creating
            // a new empty view.
            if let newPV = self.paneViews[newPaneID] {
                if let gv = gv {
                    newPV.insertGhosttyView(gv, for: tab.id)
                } else if let cv = cv {
                    newPV.insertContentView(cv, for: tab.id)
                }
            }

            // Restart all pane sessions
            for id in workspace.splitTree.leafIDs {
                if let pv = self.paneViews[id] {
                    pv.tabDragCoordinator = self.tabDragCoordinator
                    pv.startActiveSession()
                }
            }

            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            DispatchQueue.main.async { [weak self] in
                guard let self, let newPV = self.paneViews[newPaneID] else { return }
                newPV.focusActiveView()
            }
        }
    }

    /// Close an empty pane after its last tab was dragged out.
    func closeEmptyPane(_ paneID: UUID) {
        guard let workspace = activeWorkspace else { return }

        previousFocusedTabID = nil

        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.stopAll()

        guard workspace.closePane(paneID) else { return }

        let validIDs = Set(workspace.splitTree.leafIDs)
        for id in paneViews.keys where !validIDs.contains(id) {
            paneViews.removeValue(forKey: id)
        }

        splitContainer.update(tree: workspace.displayedTree)

        DispatchQueue.main.async { [weak self] in
            guard let self, let ws = self.activeWorkspace else { return }
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
}
