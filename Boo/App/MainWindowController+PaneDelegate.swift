import Cocoa

// MARK: - PaneViewDelegate

extension MainWindowController: PaneViewDelegate {
    private func activeWorkspaceForPaneEvent(_ paneID: UUID, event: String) -> Workspace? {
        guard let workspace = activeWorkspace else { return nil }
        guard workspace.pane(for: paneID) != nil else {
            let owner = appState.workspaceContainingPane(paneID)
            debugLog(
                "[WorkspaceSwitch] ignoredPaneEvent event=\(event) pane=\(paneID.uuidString) activeWorkspace=\(workspace.id.uuidString) owner=\(owner?.id.uuidString ?? "none")"
            )
            booLog(
                .debug, .terminal,
                "ignoring \(event) for pane=\(paneID.uuidString.prefix(8)) activeWorkspace=\(workspace.id.uuidString.prefix(8)) owner=\(owner?.id.uuidString.prefix(8) ?? "none")"
            )
            return nil
        }
        return workspace
    }

    func paneView(_ paneView: PaneView, didFocus paneID: UUID) {
        guard let workspace = activeWorkspaceForPaneEvent(paneID, event: "focus") else { return }
        if paneID != workspace.activePaneID {
            savePluginStateForActiveTab()
        }

        // Debounce: skip if the same pane *and* the same tab re-focused within 250ms.
        // Sidebar rebuilds can steal first responder from GhosttyView, causing
        // Ghostty to re-fire the focus callback and creating a feedback loop.
        // The tab check is load-bearing: adding a tab re-focuses the same pane, and
        // swallowing that event would leave the bridge on the old tab's remote session
        // (a new tab in an SSH pane would render as "host:path").
        let activeTabID = workspace.pane(for: paneID)?.activeTab?.id
        let now = DispatchTime.now().uptimeNanoseconds
        if paneID == lastFocusedPaneID, activeTabID == lastFocusedTabID,
            now - lastFocusTimestamp < 250_000_000
        {
            return
        }
        lastFocusedPaneID = paneID
        lastFocusedTabID = activeTabID
        lastFocusTimestamp = now

        workspace.activePaneID = paneID
        for (id, pv) in paneViews { pv.isFocused = id == paneID }
        TmuxControlClient.owning(workspace: workspace.id)?.focus(pane: paneID)

        if let pane = workspace.pane(for: paneID) {
            if pane.setActivity(false, at: pane.activeTabIndex) { refreshToolbar() }
            // Unconditional: `activateTab` clears the dot before focus lands here.
            ActivityNotifier.shared.clearDelivered(paneID: paneID, tabIndex: pane.activeTabIndex)
        }
        if let tabID = workspace.pane(for: paneID)?.activeTab?.id {
            AgentInbox.shared.markSeen(tabID: tabID)
        }

        let tab = workspace.pane(for: paneID)?.activeTab
        let cwd = tab?.workingDirectory ?? workspace.folderPath
        debugLog(
            "[WorkspaceSwitch] didFocus workspace=\(workspace.id.uuidString) pane=\(paneID.uuidString) cwd=\(cwd)"
        )

        booLog(
            .debug, .terminal,
            "didFocus: paneID=\(paneID), tabTitle=\(tab?.title ?? "nil"), cwd=\(cwd), tabRemote=\(String(describing: tab?.remoteSession)), tabRemoteCwd=\(String(describing: tab?.remoteWorkingDirectory))"
        )
        booLog(
            .debug, .terminal,
            "didFocus pane=\(paneID.uuidString.prefix(8)) tab=\(tab?.id.uuidString.prefix(8) ?? "nil") title=\(tab?.title ?? "nil") process=\(tab?.state.foregroundProcess ?? "nil")"
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
                displacedPluginTabID = nil
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
        guard let workspace = activeWorkspaceForPaneEvent(paneID, event: "cwdChanged"),
            workspace.activePaneID == paneID
        else { return }
        bridge.handleDirectoryChange(path: path, paneID: paneID)
        // Coordinator syncs bridge state → TabState
        if let pane = workspace.pane(for: paneID) {
            coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
        }
        syncRemoteSidebarState()
    }

    func paneView(_ paneView: PaneView, titleChanged title: String, paneID: UUID) {
        guard let workspace = activeWorkspaceForPaneEvent(paneID, event: "titleChanged") else { return }
        let findBarActive = paneViews[paneID]?.isFindBarVisible ?? false
        if findBarActive { return }
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
        guard activeWorkspaceForPaneEvent(paneID, event: "directoryListing") != nil else { return }
        bridge.handleDirectoryListing(path: path, output: output, paneID: paneID)
    }

    func paneView(_ paneView: PaneView, shellPIDDiscovered pid: pid_t, paneID: UUID, tabID: UUID?) {
        guard activeWorkspaceForPaneEvent(paneID, event: "shellPIDDiscovered") != nil else { return }
        bridge.monitor.track(paneID: paneID, shellPID: pid, tabID: tabID)
    }

    func paneView(_ paneView: PaneView, commandStarted command: String, paneID: UUID, tabID: UUID?) {
        bridge.monitor.nudge()
        if let workspace = appState.workspaceContainingPane(paneID),
            let pane = workspace.pane(for: paneID)
        {
            let tabIndex = tabID.flatMap { id in pane.tabs.firstIndex { $0.id == id } } ?? pane.activeTabIndex
            pane.setCommandRunning(true, at: tabIndex)
            if pane.tabs.indices.contains(tabIndex) {
                CommandLog.shared.commandStarted(tabID: pane.tabs[tabIndex].id)
                pendingReveals.removeValue(forKey: pane.tabs[tabIndex].id)?()
            }
            booLog(
                .debug, .terminal,
                "[Activity] cmd_start pane=\(paneID.uuidString.prefix(8)) tab=\(tabIndex) cmd=\(command.prefix(40))"
            )
            if workspace.id == appState.activeWorkspace?.id {
                bridge.handleCommandStart(command: command, paneID: paneID)
                BooSocketServer.shared.emitCommandStarted(command: command, paneID: paneID)
                pluginRegistry.notifyCommandStarted(command: command, context: pluginRegistry.lastContext ?? .empty)
                schedulePluginCycle(reason: .processChanged)
            }
        }
    }

    func paneView(_ paneView: PaneView, commandEnded exitCode: Int32, paneID: UUID, tabID: UUID?) {
        bridge.monitor.nudge()
        guard let workspace = appState.workspaceContainingPane(paneID) else {
            booLog(
                .debug, .terminal,
                "[Activity] cmd_end pane=\(paneID.uuidString.prefix(8)) exit=\(exitCode) — no workspace found, dropped")
            return
        }

        if workspace.id == appState.activeWorkspace?.id {
            if let result = bridge.handleCommandEnd(exitCode: exitCode, paneID: paneID) {
                BooSocketServer.shared.emitCommandEnded(result: result, paneID: paneID)
                pluginRegistry.notifyCommandEnded(result: result, context: pluginRegistry.lastContext ?? .empty)
                schedulePluginCycle(reason: .processChanged)
            }
        }

        guard let pane = workspace.pane(for: paneID) else { return }

        // Resolution order:
        // (a) tabID-resolved index (event carries the originating tab's UUID),
        // (b) pane.runningCommandTabIndex() (tab that has isCommandRunning set — user may have
        //     switched away from the originating tab between cmd_start and cmd_end),
        // (c) pane.activeTabIndex fallback for native OSC 133 COMMAND_FINISHED events (e.g.
        //     Claude Code) that fire without a prior BOO_CMD:cmd_start.
        let tabIndex: Int
        if let tabID, let idx = pane.tabs.firstIndex(where: { $0.id == tabID }) {
            tabIndex = idx
        } else if let runningIdx = pane.runningCommandTabIndex() {
            tabIndex = runningIdx
        } else {
            tabIndex = pane.activeTabIndex
        }
        guard tabIndex >= 0 else { return }
        pane.setCommandRunning(false, at: tabIndex)
        var duration: TimeInterval?
        if pane.tabs.indices.contains(tabIndex) {
            let tab = pane.tabs[tabIndex]
            if let finished = CommandLog.finishedCommand(
                record: paneView.terminalView(forTab: tab.id)?.commandHistory.last, tab: tab,
                workspaceID: workspace.id, paneID: pane.id)
            {
                CommandLog.shared.publish(finished)
                duration = finished.duration
            }
        }

        signalActivity(paneID: paneID, tabIndex: tabIndex, exitCode: exitCode, duration: duration)
    }

    func signalActivity(
        paneID: UUID, tabIndex: Int, exitCode: Int32, duration: TimeInterval? = nil, skipIfFocused: Bool = true
    ) {
        guard let workspace = appState.workspaceContainingPane(paneID),
            let pane = workspace.pane(for: paneID)
        else { return }
        signalActivity(
            workspace: workspace, pane: pane, tabIndex: tabIndex, exitCode: exitCode, duration: duration,
            skipIfFocused: skipIfFocused)
    }

    /// True when this exact workspace + pane + tab is the one the user is looking at.
    /// Notifications are suppressed for the focused tab — the user already sees it.
    func isTabFocused(workspace: Workspace, pane: Pane, tabIndex: Int) -> Bool {
        workspace.id == appState.activeWorkspace?.id
            && workspace.activePaneID == pane.id
            && pane.activeTabIndex == tabIndex
            && NSApp.isActive && window?.isKeyWindow == true
    }

    /// Resolve a tab index from an optional tab ID, falling back to the pane's active tab.
    private func tabIndex(in pane: Pane, for tabID: UUID?) -> Int? {
        if let tabID, let idx = pane.tabs.firstIndex(where: { $0.id == tabID }) { return idx }
        return pane.activeTabIndex >= 0 ? pane.activeTabIndex : nil
    }

    /// Light the tab's activity dot, raise the pane-wide activity frame, and repaint chrome.
    /// Agent hook asked for attention: tab dot plus a notification saying why.
    func signalAgentAttention(workspace: Workspace, pane: Pane, tabIndex: Int, body: String) {
        guard tabIndex >= 0, tabIndex < pane.tabs.count else { return }
        markActivity(workspace: workspace, pane: pane, tabIndex: tabIndex)
        ActivityNotifier.shared.notifyAgent(
            workspaceName: workspace.displayName, body: body, workspaceID: workspace.id, paneID: pane.id,
            tabIndex: tabIndex)
    }

    /// A trigger rule's `markTab` action: marks the tab like background
    /// activity, with the rule's id as the reason. Focusing the tab clears it.
    func markTabFromTrigger(ruleID: String, workspace: Workspace, pane: Pane, tabIndex: Int) {
        guard !isTabFocused(workspace: workspace, pane: pane, tabIndex: tabIndex) else { return }
        pane.setTriggerMark(ruleID, at: tabIndex)
        markActivity(workspace: workspace, pane: pane, tabIndex: tabIndex)
    }

    /// Redraws a pane's tab bar after tab state changed outside it (profile).
    func refreshTabBar(workspace: Workspace, pane: Pane) {
        if let pv = workspacePaneViews[workspace.id]?[pane.id] {
            pv.needsDisplay = true
            pv.updatePaneControls()
        }
        refreshToolbar()
    }

    private func markActivity(workspace: Workspace, pane: Pane, tabIndex: Int) {
        pane.setActivity(true, at: tabIndex)
        if let pv = workspacePaneViews[workspace.id]?[pane.id] {
            pv.updateActivityBorder()
            pv.needsDisplay = true
        }
        refreshToolbar()
    }

    /// `duration` gates the notification (Notifications › minimum duration), never the dot.
    func signalActivity(
        workspace: Workspace, pane: Pane, tabIndex: Int, exitCode: Int32, duration: TimeInterval? = nil,
        skipIfFocused: Bool = true
    ) {
        guard tabIndex >= 0, tabIndex < pane.tabs.count else { return }

        if skipIfFocused {
            guard !isTabFocused(workspace: workspace, pane: pane, tabIndex: tabIndex) else { return }
        }

        markActivity(workspace: workspace, pane: pane, tabIndex: tabIndex)
        let tabTitle = pane.tabs[tabIndex].state.title.isEmpty ? "Terminal" : pane.tabs[tabIndex].state.title
        ActivityNotifier.shared.notifyCommandEnded(
            tabTitle: tabTitle, workspaceName: workspace.displayName, exitCode: exitCode,
            workspaceID: workspace.id, paneID: pane.id, tabIndex: tabIndex, duration: duration)
    }

    func paneView(_ paneView: PaneView, progressChangedIn paneID: UUID) {
        refreshToolbar()
    }

    func paneView(_ paneView: PaneView, bellRangIn paneID: UUID, tabID: UUID?) {
        guard let workspace = appState.workspaceContainingPane(paneID),
            let pane = workspace.pane(for: paneID)
        else { return }

        guard let tabIndex = tabIndex(in: pane, for: tabID) else { return }

        // Always mark the activity dot; skip notification if the exact pane+tab is focused.
        markActivity(workspace: workspace, pane: pane, tabIndex: tabIndex)
        RemoteAgentTracker.shared.attentionRequested(tabID: pane.tabs[tabIndex].id)

        if !isTabFocused(workspace: workspace, pane: pane, tabIndex: tabIndex) {
            let tabTitle = pane.tabs[tabIndex].state.title.isEmpty ? "Terminal" : pane.tabs[tabIndex].state.title
            ActivityNotifier.shared.notifyBell(
                tabTitle: tabTitle, workspaceName: workspace.displayName,
                workspaceID: workspace.id, paneID: pane.id, tabIndex: tabIndex)
        }
    }

    func paneView(
        _ paneView: PaneView, desktopNotificationTitle title: String, body: String, paneID: UUID, tabID: UUID?
    ) {
        guard let workspace = appState.workspaceContainingPane(paneID),
            let pane = workspace.pane(for: paneID)
        else { return }

        guard let tabIndex = tabIndex(in: pane, for: tabID) else { return }

        // Mark activity dot on the tab even for desktop notifications.
        markActivity(workspace: workspace, pane: pane, tabIndex: tabIndex)
        RemoteAgentTracker.shared.attentionRequested(
            tabID: pane.tabs[tabIndex].id, message: body.isEmpty ? nil : body)

        // Deliver the process-requested notification unless the exact pane+tab is focused.
        if !isTabFocused(workspace: workspace, pane: pane, tabIndex: tabIndex) {
            ActivityNotifier.shared.notifyDesktop(
                title: title, body: body, workspaceName: workspace.displayName,
                workspaceID: workspace.id, paneID: pane.id, tabIndex: tabIndex)
        }
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
        moveTabs(
            fromPane: paneID, count: 1, toWorkspaceAt: workspaceIndex,
            extract: { pane in pane.extractTab(at: index).map { [$0] } ?? [] },
            insert: { pane, tabs in
                let insertIndex = pane.tabs.count
                pane.insertTab(tabs[0], at: insertIndex)
                return insertIndex
            })
    }

    func paneView(
        _ paneView: PaneView, didRequestMoveGroup groupID: UUID, toWorkspaceAt workspaceIndex: Int, paneID: UUID
    ) {
        let count = paneView.pane.tabs.filter { $0.groupID == groupID }.count
        guard count > 0 else { return }
        var moved: TabGroup?
        moveTabs(
            fromPane: paneID, count: count, toWorkspaceAt: workspaceIndex,
            extract: { pane in
                guard let (group, tabs) = pane.extractGroup(groupID) else { return [] }
                moved = group
                return tabs
            },
            insert: { pane, tabs in
                let insertIndex = pane.tabs.count
                if let moved { pane.insertGroup(moved, tabs: tabs, at: insertIndex) }
                return insertIndex
            })
    }

    /// Moves `count` tabs (pulled out by `extract`) and their live views into the
    /// destination workspace's active pane; closes the source pane or workspace
    /// if that empties it. `insert` returns the index to activate.
    private func moveTabs(
        fromPane paneID: UUID, count: Int, toWorkspaceAt workspaceIndex: Int,
        extract: (Pane) -> [Pane.Tab], insert: (Pane, [Pane.Tab]) -> Int
    ) {
        guard workspaceIndex >= 0, workspaceIndex < appState.workspaces.count else { return }
        guard let sourceWorkspace = appState.workspaces.first(where: { $0.panes[paneID] != nil }),
            let sourcePane = sourceWorkspace.pane(for: paneID),
            let pv = workspacePaneViews[sourceWorkspace.id]?[paneID]
        else { return }

        let isLastTabInWorkspace = sourceWorkspace.totalTabCount == count

        if isLastTabInWorkspace && appState.workspaces.count <= 1 {
            // Only workspace — can't move, nothing to move to
            return
        }

        let destWorkspace = appState.workspaces[workspaceIndex]
        let destPaneID = destWorkspace.activePaneID
        if sourcePane.tmuxOwned {
            if destWorkspace !== sourceWorkspace, destWorkspace.tmuxWindowID != nil {
                tmuxMovePane(paneID, toWorkspace: destWorkspace)
            }
            return
        }
        guard let destPane = destWorkspace.pane(for: destPaneID), !destPane.tmuxOwned
        else { return }

        // Extract the tabs and their views from the source pane
        let tabs = extract(sourcePane)
        guard !tabs.isEmpty else { return }
        let gvs = tabs.compactMap { tab in
            tab.contentType == .terminal ? pv.extractGhosttyView(for: tab.id).map { (tab.id, $0) } : nil
        }
        let cvs = tabs.compactMap { tab in
            tab.contentType != .terminal ? pv.extractContentView(for: tab.id).map { (tab.id, $0) } : nil
        }

        // Restore source view if it still has tabs
        if !sourcePane.tabs.isEmpty {
            pv.startActiveSession()
            pv.layoutTerminalView()
            pv.needsDisplay = true
        }

        // Insert tabs into destination workspace's active pane
        let insertIndex = insert(destPane, tabs)

        // Cache the views in the destination pane view (if it exists)
        if let destPV = workspacePaneViews[destWorkspace.id]?[destPaneID] {
            for (id, gv) in gvs { destPV.insertGhosttyView(gv, for: id) }
            for (id, cv) in cvs { destPV.insertContentView(cv, for: id) }
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

        // Switch to destination workspace so user sees where tabs landed
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
        // Closed tabs leave the agent inbox once the close has run.
        DispatchQueue.main.async { AgentInbox.shared.prune() }
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: paneID),
            let pv = paneViews[paneID]
        else { return }

        let tab = pane.tabs[index]

        // Non-terminal tabs (browser, editor, image viewer, etc.) close immediately —
        // no "end terminal session" confirmation needed.
        let tabID = tab.id
        guard tab.contentType == .terminal else {
            closeTabAfterConfirmation(paneID: paneID, tabIndex: index) { [weak self, weak pv] in
                guard let self, let pv else { return }
                if pane.tabs.count == 1 {
                    workspace.activePaneID = paneID
                    self.smartCloseAction(nil)
                } else {
                    // Re-resolve index — tabs may have changed while sheet was open.
                    guard let currentIndex = pane.tabs.firstIndex(where: { $0.id == tabID })
                    else { return }
                    pv.closeTab(at: currentIndex)
                    self.refreshStatusBar()
                    self.saveSession()
                }
            }
            return
        }

        guard let window = window else { return }
        let isLastTab = pane.tabs.count == 1
        let alert = NSAlert()
        alert.messageText = isLastTab ? "Close this pane?" : "Close this tab?"
        alert.informativeText = "This will end the terminal session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak pv] response in
            guard response == .alertFirstButtonReturn else { return }
            if isLastTab {
                workspace.activePaneID = paneID
                self?.smartCloseAction(nil)
            } else {
                guard let pv else { return }
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
        // Closed tabs leave the agent inbox once the close has run.
        DispatchQueue.main.async { AgentInbox.shared.prune() }
        guard let workspace = activeWorkspaceForPaneEvent(paneID, event: "sessionEnded") else { return }

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
