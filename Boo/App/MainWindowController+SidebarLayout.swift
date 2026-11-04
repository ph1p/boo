import Cocoa

// MARK: - Sidebar & Workspace Bar Layout

extension MainWindowController {
    /// Setup a vertical workspace bar on the given edge.
    func setupSideWorkspaceBar(in contentView: NSView, position: WorkspaceBarPosition) {
        let bar = WorkspaceBarView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isVertical = true
        bar.isRightAligned = position == .right
        bar.delegate = self
        // Deliberately not an island: like the toolbar and status bar it is a bare
        // strip over the backdrop, so no fill, no corner radius and no border.
        contentView.addSubview(bar)

        // The frame is wider than the strip the user sees: the extra band is scratch
        // space the expanded hover pill floats into, over the panes. The bar is added
        // after the split view so it draws on top, and its `hitTest` lets anything
        // outside the strip and that pill fall through to the terminal underneath.
        let widthConstraint = bar.widthAnchor.constraint(
            equalToConstant: WorkspaceBarView.verticalFrameWidth)
        sideWorkspaceBarWidthConstraint = widthConstraint

        let gap = IslandMetrics.gap
        // Top and bottom line up with the panes beside it, which clear the bars by
        // `barGap` — so the first pill starts level with the first pane's top edge.
        var constraints = [
            bar.topAnchor.constraint(
                equalTo: toolbar.bottomAnchor, constant: IslandMetrics.headerBottomGap),
            bar.bottomAnchor.constraint(
                equalTo: statusBar.topAnchor, constant: -IslandMetrics.footerTopGap),
            widthConstraint
        ]

        // Content clears only the *visible* strip plus one more gap — not the frame,
        // whose overhang deliberately overlaps the panes. The toolbar and split view
        // share one baseline now, so both take the same constant.
        let claimed = gap + WorkspaceBarView.verticalWidth + gap
        if position == .left {
            constraints.append(
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: gap))
            toolbarLeadingConstraint?.constant = claimed
            mainSplitLeadingConstraint?.constant = claimed
        } else {
            constraints.append(
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -gap))
            toolbarTrailingConstraint?.constant = -claimed
            mainSplitTrailingConstraint?.constant = -claimed
        }

        NSLayoutConstraint.activate(constraints)

        sideWorkspaceBar = bar
        // Hide workspace pills in the top toolbar
        toolbar.hideWorkspaces = true
        toolbar.needsDisplay = true
    }

    /// Remove the side workspace bar and restore top-embedded workspaces.
    private func removeSideWorkspaceBar() {
        sideWorkspaceBar?.removeFromSuperview()
        sideWorkspaceBar = nil
        sideWorkspaceBarWidthConstraint = nil
        // Back to the shared baseline — one inset for every region.
        let gap = IslandMetrics.gap
        toolbarLeadingConstraint?.constant = gap
        toolbarTrailingConstraint?.constant = -gap
        mainSplitLeadingConstraint?.constant = gap
        mainSplitTrailingConstraint?.constant = -gap
        toolbar.hideWorkspaces = false
        toolbar.needsDisplay = true
    }

    /// Rebuild workspace bar position (called on settings change).
    func rebuildWorkspaceBarLayout() {
        guard let contentView = window?.contentView else { return }
        // Always remove existing bar first
        if sideWorkspaceBar != nil {
            removeSideWorkspaceBar()
        }
        if currentWorkspaceBarPosition == .left || currentWorkspaceBarPosition == .right {
            setupSideWorkspaceBar(in: contentView, position: currentWorkspaceBarPosition)
        }
        refreshToolbar()
    }

    /// Apply (or re-apply) the positional constraints for the sidebar tab bar based on
    /// `AppSettings.shared.sidebarTabBarPosition`. Deactivates any previously active constraints.
    func applySidebarTabBarPositionConstraints() {
        sidebarController.applyTabBarPositionConstraints()
    }

    /// Add the sidebar and pane container to the main split view, ordered by sidebar position.
    func addSplitSubviewsInSidebarOrder() {
        if currentSidebarPosition == .left {
            mainSplitView.addSubview(sidebarContainer)
            mainSplitView.addSubview(splitContainer)
        } else {
            mainSplitView.addSubview(splitContainer)
            mainSplitView.addSubview(sidebarContainer)
        }
    }

    /// Rebuild the sidebar position within the main split view.
    func rebuildSidebarLayout() {
        let wasSidebarVisible = sidebarVisible
        splitContainer.removeFromSuperview()
        sidebarContainer.removeFromSuperview()
        addSplitSubviewsInSidebarOrder()

        if !wasSidebarVisible {
            sidebarContainer.removeFromSuperview()
        } else {
            mainSplitView.adjustSubviews()
            sidebarController.restoreActiveWorkspaceWidth()
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView {
            // The divider's min coordinate bounds whichever view sits on its left:
            // the sidebar when it's leading, the terminal when it's trailing.
            return currentSidebarPosition == .left ? SidebarLayout.minSidebarWidth : SidebarLayout.minTerminalWidth
        }
        return p
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView {
            // Mirror of the above: the max coordinate bounds the trailing view.
            let trailingMin =
                currentSidebarPosition == .left ? SidebarLayout.minTerminalWidth : SidebarLayout.minSidebarWidth
            return splitView.bounds.width - trailingMin
        }
        return p
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt i: Int) -> Bool {
        if splitView == mainSplitView { return !sidebarVisible }
        return false
    }

    func splitView(
        _ splitView: NSSplitView, effectiveRect r: NSRect, forDrawnRect d: NSRect, ofDividerAt i: Int
    ) -> NSRect {
        if splitView == mainSplitView && !sidebarVisible { return .zero }
        return r
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard splitView == mainSplitView, sidebarVisible else { return true }
        let sidebarIdx = currentSidebarPosition == .left ? 0 : 1
        return splitView.subviews[sidebarIdx] !== view
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        toggleSidebar(userInitiated: sender != nil)
    }

    /// Toggle sidebar visibility. When `userInitiated` is true, the flag is
    /// recorded so the plugin system won't auto-show the sidebar on tab switch.
    func toggleSidebar(userInitiated: Bool) {
        sidebarController.toggle(userInitiated: userInitiated)
        if userInitiated {
            saveSession()
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView else { return }
        guard splitView == mainSplitView, sidebarVisible else { return }

        // Remembering the width as the app default writes settings.json; do that
        // once the drag settles, not on every frame.
        sidebarController.syncWorkspaceSidebarState(rememberAsDefault: false)

        sidebarStateSaveTimer?.invalidate()
        sidebarStateSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sidebarController.syncWorkspaceSidebarState()
                self?.saveSession()
            }
        }
    }

    func resetSidebarWidthToDefault() {
        guard sidebarVisible else { return }
        let defaultWidth: CGFloat = 220
        var state = sidebarController.resolveEffectiveSidebarState()
        state.width = defaultWidth
        sidebarController.applyRestoredState(state)
        sidebarController.persistResolvedState(state)
        saveSession()
    }
}
