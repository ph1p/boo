import Cocoa

/// The tabs that are closed but still running, parked for "Undo Close".
/// Such a tab is in no window, yet it is not gone: its agent state, grants
/// and crew links must survive until the tab comes back or its time is up.
@MainActor
enum ParkedTabs {
    private static var ids: Set<UUID> = []

    static func contains(_ id: UUID) -> Bool { ids.contains(id) }
    static func insert(_ added: [UUID]) { ids.formUnion(added) }
    static func remove(_ removed: [UUID]) { ids.subtract(removed) }
}

/// A pane taken out of its workspace with its view and running sessions.
struct ParkedPane {
    let pane: Pane
    let view: PaneView
    let workspaceID: UUID
    /// Where the pane sat in the split layout.
    let slot: SplitTree.Slot
}

/// What a closed item keeps alive while the close can still be undone.
enum ParkedItem {
    case tab(DetachedTab, paneID: UUID, index: Int)
    case pane(ParkedPane)
    case workspace(DetachedWorkspace, index: Int)

    @MainActor
    var tabIDs: [UUID] {
        switch self {
        case .tab(let parked, _, _): return [parked.tab.id]
        case .pane(let parked): return parked.pane.tabs.map(\.id)
        case .workspace(let detached, _): return detached.workspace.panes.values.flatMap { $0.tabs.map(\.id) }
        }
    }

    /// The terminal views of the item, shown or cached.
    @MainActor
    var terminalViews: [GhosttyView] {
        switch self {
        case .tab(let parked, _, _): return parked.ghosttyView.map { [$0] } ?? []
        case .pane(let parked): return Array(parked.view.terminalViewsByTab.values)
        case .workspace(let detached, _):
            return detached.paneViews.values.flatMap { $0.terminalViewsByTab.values }
        }
    }

    /// Ends the sessions for good: the close can no longer be undone.
    @MainActor
    func destroy() {
        let ids = tabIDs
        ParkedTabs.remove(ids)
        switch self {
        case .tab(let parked, _, _):
            parked.ghosttyView?.muteCallbacks()
            parked.ghosttyView?.destroy()
        case .pane(let parked):
            parked.view.stopAll()
            parked.pane.stopAll()
        case .workspace(let detached, _):
            for entry in detached.undoItems { entry.live?.destroy() }
            for view in detached.paneViews.values { view.stopAll() }
            detached.workspace.stopAll()
            AppSettings.shared.removeWorkspacesFromGroups([detached.workspace.id.uuidString])
        }
        for id in ids {
            CommandLog.shared.tabClosed(id)
            // The first notice was held back while the tab was parked.
            OrchestratorEvents.shared.terminalClosed(id)
        }
        DispatchQueue.main.async { AgentInbox.shared.prune() }
    }
}

/// How much of a close can be undone.
enum CloseUndo {
    /// Keep the sessions running for the undo time, then fall back.
    case live
    /// Reopen a fresh shell in the old folder.
    case fallback
    case none
}

extension MainWindowController {
    /// Seconds a closed item stays alive; 0 turns live undo off.
    var undoCloseLifetime: TimeInterval { TimeInterval(AppSettings.shared.undoCloseSeconds) }

    // MARK: - Closing

    /// Closes one tab of a pane that keeps at least one other tab.
    func closeTab(in pv: PaneView, at index: Int, undo: CloseUndo, announce: Bool = true) {
        let pane = pv.pane
        guard index >= 0, index < pane.tabs.count else { return }
        let tab = pane.tabs[index]
        let isTerminal = tab.contentType == .terminal
        let exited = exitedTabIDs.remove(tab.id) != nil
        let fallback: ClosedItem? =
            undo != .none && isTerminal
            ? .tab(paneID: pv.paneID, workingDirectory: tab.workingDirectory, index: index) : nil

        if undo == .live, !exited, undoCloseLifetime > 0, isTerminal, !pane.tmuxOwned {
            // Before the close notice, so the tab does not count as gone.
            ParkedTabs.insert([tab.id])
            if let parked = pv.parkTab(at: index) {
                notifyTerminalClosed(for: tab.id)
                parked.ghosttyView?.muteCallbacks()
                let live = ParkedItem.tab(parked, paneID: pv.paneID, index: index)
                let id = closedItems.push(
                    fallback: fallback, live: live, lifetime: undoCloseLifetime, paneIDs: [pv.paneID])
                watchForExit(of: live.terminalViews, entry: id)
                refreshStatusBar()
                saveSession()
                if announce { announceClose("Tab closed", entry: id) }
                return
            }
            ParkedTabs.remove([tab.id])
        }

        if let fallback { pushUndo(fallback) }
        notifyTerminalClosed(for: tab.id)
        pv.closeTab(at: index)
        refreshStatusBar()
        saveSession()
    }

    /// Closes the active pane. With one pane left it closes the workspace.
    func closeActivePane(undo: CloseUndo, announce: Bool = true) {
        guard let workspace = activeWorkspace else { return }
        let paneID = workspace.activePaneID
        booLog(
            .debug, .terminal, "closing pane=\(paneID.uuidString.prefix(8)) remainingPanes=\(workspace.panes.count - 1)"
        )
        let pane = workspace.pane(for: paneID)
        let hasSiblings = workspace.panes.count > 1
        var exited = false
        for tab in pane?.tabs ?? [] where exitedTabIDs.remove(tab.id) != nil { exited = true }

        var fallback: ClosedItem?
        if undo != .none, hasSiblings {
            fallback = .pane(
                siblingPaneID: findSiblingID(for: paneID, in: workspace.splitTree) ?? paneID,
                workingDirectory: pane?.activeTab?.workingDirectory ?? workspace.folderPath,
                direction: findSplitDirection(for: paneID, in: workspace.splitTree) ?? .horizontal)
        }

        if undo == .live, !exited, undoCloseLifetime > 0, hasSiblings, let pane, !pane.tmuxOwned,
            workspace.tmuxWindowID == nil, let pv = paneViews[paneID],
            let slot = workspace.splitTree.slot(of: paneID)
        {
            ParkedTabs.insert(pane.tabs.map(\.id))
            notifyTerminalClosed(for: pane.tabs)
            previousFocusedTabID = nil
            bridge.monitor.untrack(paneID: paneID)
            paneViews.removeValue(forKey: paneID)
            pv.persistContentStateToModel()
            pv.paneDelegate = nil
            _ = workspace.closePane(paneID, stopping: false)
            let live = ParkedItem.pane(ParkedPane(pane: pane, view: pv, workspaceID: workspace.id, slot: slot))
            let id = closedItems.push(
                fallback: fallback, live: live, lifetime: undoCloseLifetime, paneIDs: Set(slot.siblingLeaves))
            watchForExit(of: live.terminalViews, entry: id)
            finishPaneRemoval(in: workspace)
            pv.removeFromSuperview()
            if announce { announceClose("Pane closed", entry: id) }
            return
        }

        if let fallback { pushUndo(fallback) }
        if hasSiblings, let pane { notifyTerminalClosed(for: pane.tabs) }

        // Clear the previous-tab tracker so the stale bridge state
        // (which still holds the closed pane's title/cwd) is not
        // synced onto the surviving pane's tab when it gains focus.
        previousFocusedTabID = nil

        // Remove the closed pane's view from cache
        bridge.monitor.untrack(paneID: paneID)
        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.stopAll()

        if workspace.closePane(paneID) {
            finishPaneRemoval(in: workspace)
        } else {
            toolbarDidCloseWorkspace(at: appState.activeWorkspaceIndex)
        }
    }

    /// Lays the workspace out again after a pane left it.
    private func finishPaneRemoval(in workspace: Workspace) {
        let validIDs = Set(workspace.splitTree.leafIDs)

        for id in paneViews.keys where !validIDs.contains(id) {
            paneViews.removeValue(forKey: id)
        }

        splitContainer.update(tree: workspace.displayedTree)
        saveSession()
        settlePanes(of: workspace)
    }

    /// After a pane left or rejoined `workspace`: restarts the sessions,
    /// refreshes the surfaces and focuses `paneID` (nil: the active pane).
    private func settlePanes(of workspace: Workspace, focus paneID: UUID? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeWorkspace != nil else { return }
            for id in workspace.splitTree.leafIDs { self.paneViews[id]?.startActiveSession() }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            self.runPluginCycle(reason: .focusChanged)
            DispatchQueue.main.async { [weak self] in
                guard let self, let id = paneID ?? self.activeWorkspace?.activePaneID else { return }
                self.paneViews[id]?.focusActiveView()
            }
        }
    }

    /// Takes a workspace out of the window with its sessions running. False
    /// when it can't be parked; the caller then closes it for good.
    func parkWorkspace(at index: Int) -> Bool {
        guard undoCloseLifetime > 0, appState.workspaces.count > 1, index >= 0, index < appState.workspaces.count
        else { return false }
        let ws = appState.workspaces[index]
        let tabIDs = ws.panes.values.flatMap { $0.tabs.map(\.id) }
        guard ws.tmuxWindowID == nil, !ws.panes.values.contains(where: \.tmuxOwned),
            exitedTabIDs.isDisjoint(with: tabIDs)
        else { return false }

        ParkedTabs.insert(tabIDs)
        guard let detached = detachWorkspace(at: index) else {
            ParkedTabs.remove(tabIDs)
            return false
        }
        for pv in detached.paneViews.values {
            pv.paneDelegate = nil
            pv.removeFromSuperview()
        }
        let live = ParkedItem.workspace(detached, index: index)
        let id = closedItems.push(fallback: nil, live: live, lifetime: undoCloseLifetime)
        watchForExit(of: live.terminalViews, entry: id)
        announceClose("Workspace closed", entry: id)
        return true
    }

    /// A parked shell that exits takes its entry's live payload with it: a
    /// dead terminal is not worth bringing back.
    private func watchForExit(of views: [GhosttyView], entry id: UUID?) {
        guard let id else { return }
        for view in views {
            view.onProcessExited = { [weak self] in
                // Not inside the view's own callback: dropping destroys the view.
                DispatchQueue.main.async { self?.closedItems.dropLive(id: id) }
            }
        }
    }

    private func announceClose(_ message: String, entry id: UUID?) {
        guard let id else { return }
        let undo = BooAlert.ToastAction(title: "Undo") { [weak self] in
            guard let self, let entry = self.closedItems.take(id: id) else { return }
            self.reopen(entry)
        }
        BooAlert.showTransient(message, actions: [undo], lifetime: min(undoCloseLifetime, 10))
    }

    // MARK: - Reopening

    func pushUndo(_ item: ClosedItem) {
        closedItems.push(fallback: item, paneIDs: [item.paneID])
    }

    @objc func reopenTabAction(_ sender: Any?) {
        guard let entry = closedItems.popLast() else { return }
        reopen(entry)
    }

    /// Brings a closed item back: the running one when it is still there,
    /// else a fresh shell in the old folder.
    func reopen(_ entry: ClosedItemStore<ParkedItem>.Entry) {
        if let live = entry.live {
            if restore(live) { return }
            live.destroy()
        }
        if let fallback = entry.fallback { reopenFresh(fallback) }
    }

    /// Puts a parked item back. False, with nothing changed, when its place
    /// is gone.
    private func restore(_ live: ParkedItem) -> Bool {
        switch live {
        case .tab(let parked, let paneID, let index):
            let workspace: Workspace?
            if let home = appState.workspaceContainingPane(paneID),
                let homeIndex = appState.workspaces.firstIndex(where: { $0.id == home.id })
            {
                if homeIndex != appState.activeWorkspaceIndex { activateWorkspace(homeIndex) }
                workspace = home
            } else {
                // The pane is gone: the tab joins the active pane.
                workspace = activateContentWorkspace()
            }
            guard let workspace,
                let dest = paneViews[workspace.pane(for: paneID) != nil ? paneID : workspace.activePaneID],
                !dest.pane.tmuxOwned
            else { return false }
            ParkedTabs.remove([parked.tab.id])
            insertDroppedTab(
                parked.tab, ghosttyView: parked.ghosttyView, contentView: nil, into: dest,
                zone: .tabBarInsert(index: index), workspace: workspace)
            dest.rewireTerminals()
            trackShell(of: parked.ghosttyView, paneID: dest.paneID, tabID: parked.tab.id)
            saveSession()
            refreshStatusBar()
            return true

        case .pane(let parked):
            guard let wsIndex = appState.workspaces.firstIndex(where: { $0.id == parked.workspaceID }),
                appState.workspaces[wsIndex].tmuxWindowID == nil
            else { return false }
            let workspace = appState.workspaces[wsIndex]
            if wsIndex != appState.activeWorkspaceIndex { activateWorkspace(wsIndex) }
            ParkedTabs.remove(live.tabIDs)
            window?.makeFirstResponder(nil)
            if workspace.zoomedPaneID != nil { setZoomedPane(nil, in: workspace) }
            workspace.restorePane(parked.pane, at: parked.slot)
            let pv = parked.view
            let paneID = parked.pane.id
            paneViews[paneID] = pv
            pv.paneDelegate = self
            pv.tabDragCoordinator = tabDragCoordinator
            pv.rewireTerminals()
            updateSplits(workspace.displayedTree, fadingIn: paneID)
            trackShell(of: pv.ghosttyView, paneID: paneID, tabID: parked.pane.activeTab?.id)
            saveSession()
            settlePanes(of: workspace, focus: paneID)
            refreshStatusBar()
            return true

        case .workspace(let detached, let index):
            ParkedTabs.remove(live.tabIDs)
            for pv in detached.paneViews.values { pv.rewireTerminals() }
            adoptWorkspace(detached, at: min(index, appState.workspaces.count))
            return true
        }
    }

    /// Reopens a closed tab or pane as a fresh shell in its old folder.
    private func reopenFresh(_ item: ClosedItem) {
        // tmux panes hold no tabs: reopen in a regular workspace.
        guard let workspace = activateContentWorkspace() else { return }

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
}
