import Cocoa

extension PaneDirection {
    /// Parses Ghostty's direction names ("left", "right", "up", "down").
    init?(name: String) {
        switch name {
        case "left": self = .left
        case "right": self = .right
        case "up": self = .up
        case "down": self = .down
        default: return nil
        }
    }
}

// MARK: - Pane layout control (focus, resize, swap, zoom)

extension MainWindowController {
    /// Size the active workspace's panes are laid out in (a square fallback
    /// before the window has a size, which keeps directions meaningful).
    private var splitLayoutSize: CGSize {
        let size = splitContainer.bounds.size
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1000, height: 1000)
    }

    func cyclePaneFocus(by step: Int) {
        guard let workspace = activeWorkspace else { return }
        let ids = workspace.splitTree.leafIDs
        guard ids.count > 1, let index = ids.firstIndex(of: workspace.activePaneID) else { return }
        focusPane(ids[(index + step + ids.count) % ids.count], in: workspace)
    }

    /// Focus the pane next to the active one in `direction`.
    func focusPane(_ direction: PaneDirection) {
        guard let workspace = activeWorkspace,
            let target = workspace.splitTree.neighbor(
                of: workspace.activePaneID, toward: direction, in: splitLayoutSize)
        else { return }
        focusPane(target, in: workspace)
    }

    /// Make `paneID` active and focused, leaving zoom when it was hidden.
    private func focusPane(_ paneID: UUID, in workspace: Workspace) {
        revealPane(paneID, in: workspace)
        workspace.activePaneID = paneID
        updatePaneCloseButtons()
        paneViews[paneID]?.focusActiveView()
        runPluginCycle(reason: .focusChanged)
    }

    /// Leave zoom when it hides `paneID`, so focusing it shows it.
    func revealPane(_ paneID: UUID, in workspace: Workspace) {
        guard let zoomed = workspace.zoomedPaneID, zoomed != paneID else { return }
        setZoomedPane(nil, in: workspace)
    }

    /// Move the divider next to the active pane `amount` points toward `direction`.
    func resizeActivePane(toward direction: PaneDirection, by amount: CGFloat) {
        guard let workspace = activeWorkspace, workspace.zoomedPaneID == nil else { return }
        let resized = workspace.splitTree.resizing(
            leafID: workspace.activePaneID, toward: direction, by: amount, in: splitLayoutSize,
            minimum: splitContainer.minPaneDimension)
        guard resized != workspace.splitTree else { return }
        workspace.splitTree = resized
        splitContainer.update(tree: workspace.displayedTree)
        scheduleSplitRatioSave()
    }

    /// Swap the active pane with its neighbor in `direction`; focus moves with it.
    func swapActivePane(toward direction: PaneDirection) {
        guard let workspace = activeWorkspace else { return }
        let active = workspace.activePaneID
        guard let target = workspace.splitTree.neighbor(of: active, toward: direction, in: splitLayoutSize)
        else { return }
        workspace.splitTree = workspace.splitTree.swappingLeaves(active, target)
        applyStructuralLayoutChange(in: workspace)
        saveSession()
    }

    /// Show only `paneID` (nil shows every pane again).
    func setZoomedPane(_ paneID: UUID?, in workspace: Workspace) {
        workspace.zoomedPaneID = paneID
        guard workspace === activeWorkspace else { return }
        applyStructuralLayoutChange(in: workspace)
    }

    /// Re-render after panes moved in or out of the hierarchy: re-parented
    /// surfaces need a refresh once layout settles.
    private func applyStructuralLayoutChange(in workspace: Workspace) {
        splitContainer.update(tree: workspace.displayedTree)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeWorkspace === workspace else { return }
            self.refreshAllSurfaces()
            self.updatePaneCloseButtons()
            self.paneViews[workspace.activePaneID]?.focusActiveView()
        }
    }

    func scheduleSplitRatioSave() {
        splitRatioSaveTimer?.invalidate()
        splitRatioSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    // MARK: Menu actions

    @objc func toggleZoomPaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        if workspace.zoomedPaneID != nil {
            setZoomedPane(nil, in: workspace)
        } else if workspace.splitTree.leafCount > 1 {
            setZoomedPane(workspace.activePaneID, in: workspace)
        }
    }

    @objc func equalizeSplitsAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        workspace.equalizeSplits()
        splitContainer.update(tree: workspace.displayedTree)
        scheduleSplitRatioSave()
    }

    @objc func focusPaneLeftAction(_ sender: Any?) { focusPane(.left) }
    @objc func focusPaneRightAction(_ sender: Any?) { focusPane(.right) }
    @objc func focusPaneUpAction(_ sender: Any?) { focusPane(.up) }
    @objc func focusPaneDownAction(_ sender: Any?) { focusPane(.down) }

    /// Keyboard resize step, matching Ghostty's default `resize_split` amount.
    private static let resizeStep: CGFloat = 10

    @objc func resizePaneLeftAction(_ sender: Any?) { resizeActivePane(toward: .left, by: Self.resizeStep) }
    @objc func resizePaneRightAction(_ sender: Any?) { resizeActivePane(toward: .right, by: Self.resizeStep) }
    @objc func resizePaneUpAction(_ sender: Any?) { resizeActivePane(toward: .up, by: Self.resizeStep) }
    @objc func resizePaneDownAction(_ sender: Any?) { resizeActivePane(toward: .down, by: Self.resizeStep) }

    @objc func swapPaneLeftAction(_ sender: Any?) { swapActivePane(toward: .left) }
    @objc func swapPaneRightAction(_ sender: Any?) { swapActivePane(toward: .right) }
    @objc func swapPaneUpAction(_ sender: Any?) { swapActivePane(toward: .up) }
    @objc func swapPaneDownAction(_ sender: Any?) { swapActivePane(toward: .down) }
}
