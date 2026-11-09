import Cocoa

/// Keyboard navigation between workspaces, tabs and panes, and the focus
/// history behind ⌘[ / ⌘].
extension MainWindowController {
    // MARK: - Workspaces

    @objc func lastWorkspaceAction(_ sender: Any?) {
        let last = appState.workspaces.count - 1
        guard last >= 0, last != appState.activeWorkspaceIndex else { return }
        activateWorkspace(last)
    }

    @objc func nextWorkspaceAction(_ sender: Any?) { cycleWorkspace(by: 1) }
    @objc func previousWorkspaceAction(_ sender: Any?) { cycleWorkspace(by: -1) }

    func cycleWorkspace(by step: Int) {
        let count = appState.workspaces.count
        guard count > 1 else { return }
        activateWorkspace((appState.activeWorkspaceIndex + step + count) % count)
    }

    @objc func moveWorkspaceUpAction(_ sender: Any?) {
        let index = appState.activeWorkspaceIndex
        guard index > 0 else { return }
        reorderWorkspace(from: index, to: index - 1)
    }

    @objc func moveWorkspaceDownAction(_ sender: Any?) {
        let index = appState.activeWorkspaceIndex
        guard index < appState.workspaces.count - 1 else { return }
        // The destination is an insertion point before the move: past the next one.
        reorderWorkspace(from: index, to: index + 2)
    }

    @objc func goToWorkspaceAction(_ sender: Any?) {
        guard let window else { return }
        CommandPaletteController.shared.open(over: window, query: "@")
    }

    // MARK: - Tabs

    @objc func nextTabAction(_ sender: Any?) { cycleTab(by: 1) }
    @objc func previousTabAction(_ sender: Any?) { cycleTab(by: -1) }

    /// The next visible tab of the active pane, wrapping; collapsed groups are skipped.
    func cycleTab(by step: Int) {
        guard let ws = activeWorkspace, let pane = ws.pane(for: ws.activePaneID),
            let pv = paneViews[ws.activePaneID]
        else { return }
        guard
            let target = Self.nextVisibleIndex(
                from: pane.activeTabIndex, step: step, count: pane.tabs.count, isHidden: pane.isTabHidden(at:))
        else { return }
        pv.activateTab(target)
    }

    /// Steps from `index` by `step` with wrap-around, skipping hidden
    /// indices; nil when no other index is visible.
    nonisolated static func nextVisibleIndex(
        from index: Int, step: Int, count: Int, isHidden: (Int) -> Bool
    ) -> Int? {
        guard count > 1 else { return nil }
        var candidate = index
        for _ in 1..<count {
            candidate = (candidate + step + count) % count
            if !isHidden(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Panes

    @objc func focusPaneNumberAction(_ sender: NSMenuItem) {
        guard let ws = activeWorkspace else { return }
        let ids = ws.splitTree.leafIDs
        guard ids.indices.contains(sender.tag) else { return }
        focusPane(ids[sender.tag], in: ws)
    }

    @objc func pickPaneAction(_ sender: Any?) {
        showPanePicker()
    }

    // MARK: - Focus history

    @objc func focusBackAction(_ sender: Any?) { moveInFocusHistory(by: -1) }
    @objc func focusForwardAction(_ sender: Any?) { moveInFocusHistory(by: 1) }

    func recordFocus() {
        guard let ws = activeWorkspace else { return }
        focusHistory.record(
            FocusLocation(
                workspaceID: ws.id, paneID: ws.activePaneID, tabID: ws.pane(for: ws.activePaneID)?.activeTab?.id))
    }

    private func moveInFocusHistory(by step: Int) {
        let workspaces = appState.workspaces
        guard
            let location = focusHistory.move(
                by: step,
                isValid: { location in
                    workspaces.first { $0.id == location.workspaceID }?.pane(for: location.paneID) != nil
                })
        else { return }
        focusHistory.isNavigating = true
        defer { focusHistory.isNavigating = false }
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == location.workspaceID }),
            let pane = workspaces[wsIndex].pane(for: location.paneID)
        else { return }
        let workspace = workspaces[wsIndex]
        let tabIndex = location.tabID.flatMap { id in pane.tabs.firstIndex { $0.id == id } } ?? pane.activeTabIndex
        if wsIndex != appState.activeWorkspaceIndex {
            // Restored by activateWorkspace once the workspace is on screen.
            workspace.activePaneID = location.paneID
            focusActivity(workspaceID: workspace.id, paneID: location.paneID, tabIndex: tabIndex)
        } else {
            focusPane(location.paneID, in: workspace)
            if tabIndex != pane.activeTabIndex { paneViews[location.paneID]?.activateTab(tabIndex) }
        }
    }
}
