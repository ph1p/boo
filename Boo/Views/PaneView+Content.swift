import Cocoa

// MARK: - Content Lifecycle

extension PaneView {
    func startActiveSession() {
        guard let tab = pane.activeTab else { return }

        // Handle based on content type
        switch tab.contentType {
        case .terminal:
            startTerminalSession(for: tab)
        default:
            startContentSession(for: tab)
        }
        layoutTerminalView()
        updatePaneControls()
        // A restored cached surface may re-enter the hierarchy at its previous size, so
        // `ghostty_surface_set_size` does not dirty it and the pane shows stale/blank
        // content until a keystroke or resize. Force a repaint now that layout is done.
        ghosttyView?.refresh()
    }

    /// Cache `gv` for the tab that owns it, or tear it down when that tab has left this pane
    /// (closed, or moved away and already re-homed) — nothing would ever restore it.
    /// Its `wrapper` is parked (hidden, still attached) along with it.
    func retire(_ gv: GhosttyView, wrapper: TerminalScrollView?) {
        if let owner = gv.tabID, pane.tabs.contains(where: { $0.id == owner }) {
            if let wrapper {
                wrapper.isHidden = true
            } else {
                gv.removeFromSuperview()
            }
            tabViews[owner] = CachedTerminal(view: gv, wrapper: wrapper)
        } else {
            wrapper?.removeFromSuperview()
            gv.removeFromSuperview()
            gv.destroy()
        }
    }

    /// Hand the displayed terminal and its wrapper to `retire`.
    func retireDisplayedTerminal() {
        guard let gv = ghosttyView else { return }
        let wrapper = scrollWrapper
        scrollWrapper = nil
        ghosttyView = nil
        retire(gv, wrapper: wrapper)
    }

    /// Content-view counterpart to `retire(_: GhosttyView)`.
    func retire(_ cv: ContentViewProtocol) {
        cv.deactivate()
        cv.removeFromSuperview()
        if let owner = cv.tabID, pane.tabs.contains(where: { $0.id == owner }) {
            contentViews[owner] = cv
        } else {
            cv.cleanup()
        }
    }

    /// Start a terminal session for the given tab.
    private func startTerminalSession(for tab: Pane.Tab) {
        // Hide any non-terminal content view, caching it for the tab that owns it — see the
        // matching note in startContentSession.
        // A content view can never belong to this terminal tab, so it is always displaced.
        if let cv = activeContentView {
            retire(cv)
        }
        activeContentView = nil

        if let cached = tabViews.removeValue(forKey: tab.id) {
            let stored = cached.view
            retireDisplayedTerminal()
            if let parked = cached.wrapper, parked.ghosttyView === stored, parked.superview === self {
                parked.isHidden = false
                scrollWrapper = parked
                needsLayout = true
            } else {
                cached.wrapper?.removeFromSuperview()
                let wrapper = TerminalScrollView(ghosttyView: stored)
                addSubview(wrapper)
                scrollWrapper = wrapper
            }
            ghosttyView = stored
            // Always rewire callbacks — the view may have been transferred from another pane
            wireCallbacks(stored)
        } else if ghosttyView == nil {
            let gv = GhosttyView(workingDirectory: tab.workingDirectory, paneID: paneID, tabID: tab.id)
            wireCallbacks(gv)
            let wrapper = TerminalScrollView(ghosttyView: gv)
            addSubview(wrapper)
            scrollWrapper = wrapper
            ghosttyView = gv
        }
    }

    /// Start a non-terminal content session for the given tab.
    private func startContentSession(for tab: Pane.Tab) {
        // Hide the terminal view. Not every caller runs storeCurrentView first (a cross-pane
        // drop calls startActiveSession directly), so cache it here instead of dropping the
        // reference — otherwise switching from a terminal tab to a content tab loses the
        // terminal's surface and it comes back blank.
        // A terminal view can never belong to this non-terminal tab, so it is always displaced.
        retireDisplayedTerminal()

        // Check if the active content view is already for this tab (avoid double-init).
        // Match on the displayed tab id, not just the content type — two tabs of the same
        // kind (e.g. two editors) would otherwise be treated as interchangeable and the
        // incoming tab would keep showing the previous tab's view.
        if let active = activeContentView, active.superview == self, active.tabID == tab.id,
            active.contentType == tab.contentType
        {
            return
        }

        // Check cache first
        if let stored = contentViews.removeValue(forKey: tab.id) {
            // Rewire callbacks in case this view was transferred from another pane
            wireContentCallbacks(stored, tabID: tab.id)
            addSubview(stored)
            activeContentView = stored
            stored.activate()
        } else {
            // Create new content view
            let contentView = ContentViewFactory.createView(for: tab.state.contentState)
            wireContentCallbacks(contentView, tabID: tab.id)
            addSubview(contentView)
            activeContentView = contentView
            contentView.activate()
        }
    }

    /// Wire callbacks for non-terminal content views, and stamp the view with its owning tab.
    ///
    /// Every path that adopts a content view goes through here, so this is also where the
    /// view learns its identity — a transferred view gets re-stamped for its new pane.
    private func wireContentCallbacks(_ contentView: ContentViewProtocol, tabID: UUID) {
        contentView.tabID = tabID

        contentView.onFocused = { [weak self] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }

        contentView.onTitleChanged = { [weak self] title in
            guard let self else { return }
            if let index = self.pane.tabs.firstIndex(where: { $0.id == tabID }) {
                self.pane.updateTitle(at: index, title)
                self.scheduleTabBarRedraw()
            }
        }

        contentView.onCloseRequested = { [weak self] in
            guard let self else { return }
            if let index = self.pane.tabs.firstIndex(where: { $0.id == tabID }) {
                self.paneDelegate?.paneView(self, didRequestCloseTab: index, paneID: self.paneID)
            }
        }
    }

    /// Remove and return a GhosttyView for cross-pane transfer. Does not destroy it.
    /// Call AFTER extractTab — the active tab will have shifted, so we check the
    /// cache first, then fall back to the currently displayed ghosttyView.
    /// The terminal of `tabID`, displayed or cached off-screen, without moving it.
    func terminalView(forTab tabID: UUID) -> GhosttyView? {
        if let gv = ghosttyView, gv.tabID == tabID { return gv }
        return tabViews[tabID]?.view
    }

    func extractGhosttyView(for tabID: UUID) -> GhosttyView? {
        // Check the off-screen cache
        if let cached = tabViews.removeValue(forKey: tabID) {
            cached.detach()
            return cached.view
        }
        // The dragged tab was likely the active/displayed one — extractTab already
        // shifted activeTabIndex, so pane.activeTab no longer matches this tabID.
        // Hand over the displayed view only if it really belongs to this tab: dragging a
        // tab that was never displayed must return nil rather than the active tab's view.
        if let gv = ghosttyView, gv.tabID == tabID {
            // Remove from scroll wrapper without destroying
            gv.removeFromSuperview()
            scrollWrapper?.removeFromSuperview()
            scrollWrapper = nil
            ghosttyView = nil
            return gv
        }
        return nil
    }

    /// Accept a GhosttyView transferred from another pane.
    func insertGhosttyView(_ gv: GhosttyView, for tabID: UUID) {
        tabViews[tabID]?.wrapper?.removeFromSuperview()
        tabViews[tabID] = CachedTerminal(view: gv, wrapper: nil)
    }

    /// Remove and return a ContentView for cross-pane transfer. Does not destroy it.
    /// Call AFTER extractTab — the active tab will have shifted, so we check the
    /// cache first, then fall back to the currently displayed activeContentView.
    func extractContentView(for tabID: UUID) -> ContentViewProtocol? {
        // Check the off-screen cache
        if let cv = contentViews.removeValue(forKey: tabID) {
            cv.removeFromSuperview()
            return cv
        }
        // The dragged tab was likely the active/displayed one — extractTab already
        // shifted activeTabIndex, so pane.activeTab no longer matches this tabID.
        // Hand over the displayed view only if it really belongs to this tab; see the
        // matching guard in extractGhosttyView.
        if let cv = activeContentView, cv.tabID == tabID {
            cv.deactivate()
            cv.removeFromSuperview()
            activeContentView = nil
            return cv
        }
        return nil
    }

    /// Accept a ContentView transferred from another pane.
    func insertContentView(_ cv: ContentViewProtocol, for tabID: UUID) {
        contentViews[tabID] = cv
    }

    func editorView(for tabID: UUID) -> EditorContentView? {
        // Key on the view's own tab, not `pane.activeTab` — after a cross-pane drop those
        // disagree, and this feeds editor lookup/save.
        if let editor = activeContentView as? EditorContentView, editor.tabID == tabID {
            return editor
        }
        return contentViews[tabID] as? EditorContentView
    }

    private func wireCallbacks(_ gv: GhosttyView) {
        gv.onFocused = { [weak self] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }

        gv.onPwdChanged = { [weak self, tabID = gv.tabID] path in
            guard let self else { return }
            self.debounceCwdUpdate(path, tabID: tabID)
        }

        gv.onTitleChanged = { [weak self, tabID = gv.tabID] title in
            guard let self else { return }
            self.debounceTitleUpdate(title, tabID: tabID)
        }

        gv.onDirectoryListing = { [weak self] path, output in
            guard let self else { return }
            self.paneDelegate?.paneView(self, directoryListing: path, output: output, paneID: self.paneID)
        }

        gv.onProcessExited = { [weak self] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, sessionEnded: self.paneID)
        }

        gv.onShellPIDDiscovered = { [weak self, tabID = gv.tabID] pid in
            guard let self else { return }
            // Resolve the tab index from the captured tabID; fall back to activeTabIndex.
            let idx: Int
            if let tabID, let found = self.pane.tabs.firstIndex(where: { $0.id == tabID }) {
                idx = found
            } else {
                idx = self.pane.activeTabIndex
            }
            let resolvedTabID = idx >= 0 ? self.pane.tabs[idx].id : tabID
            if idx >= 0 { self.pane.updateShellPID(at: idx, pid) }
            self.paneDelegate?.paneView(self, shellPIDDiscovered: pid, paneID: self.paneID, tabID: resolvedTabID)
        }

        gv.onCommandStart = { [weak self, tabID = gv.tabID] command in
            guard let self else { return }
            self.paneDelegate?.paneView(self, commandStarted: command, paneID: self.paneID, tabID: tabID)
        }

        gv.onCommandEnd = { [weak self, tabID = gv.tabID] exitCode in
            guard let self else { return }
            // A finished command can't still be making progress.
            if let tabID { self.setProgress(nil, forTab: tabID) }
            self.paneDelegate?.paneView(self, commandEnded: exitCode, paneID: self.paneID, tabID: tabID)
        }

        gv.onHistorySearch = { [weak self, tabID = gv.tabID] view in
            guard let self, let tab = self.pane.tabs.first(where: { $0.id == tabID }) else { return }
            let controller = self.window?.windowController as? MainWindowController
            HistorySearchController.shared.open(
                for: view,
                context: HistorySearchContext(
                    workspaceID: controller?.appState.workspaceContainingPane(self.paneID)?.id,
                    host: tab.remoteSession.map(\.displayName),
                    cwd: tab.remoteSession != nil
                        ? (tab.remoteWorkingDirectory ?? tab.workingDirectory) : tab.workingDirectory))
        }

        gv.onProgressReport = { [weak self, tabID = gv.tabID] report, percent in
            guard let self, let tabID,
                let index = self.pane.tabs.firstIndex(where: { $0.id == tabID })
            else { return }
            let next = TerminalProgress.applying(report, percent: percent, to: self.pane.tabs[index].state.progress)
            self.setProgress(next, forTab: tabID)
        }

        gv.onBell = { [weak self, tabID = gv.tabID] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, bellRangIn: self.paneID, tabID: tabID)
        }

        gv.onDesktopNotification = { [weak self, tabID = gv.tabID] title, body in
            guard let self else { return }
            self.paneDelegate?.paneView(
                self,
                desktopNotificationTitle: title,
                body: body,
                paneID: self.paneID,
                tabID: tabID
            )
        }

        gv.onSearchRequested = { [weak self] needle in
            guard let self else { return }
            self.showFindBar()
            if !needle.isEmpty {
                self.ghosttyView?.updateSearch(needle: needle)
            }
        }

        gv.onSearchTotal = { [weak self] total in
            guard let self else { return }
            self.searchMatchTotal = total
            self.findBar?.updateMatches(selected: -1, total: total)
        }

        gv.onSearchSelected = { [weak self] selected in
            guard let self else { return }
            self.findBar?.updateMatches(selected: selected, total: self.searchMatchTotal)
        }

        gv.onSearchEnded = { [weak self] in
            guard let self, self.isFindBarVisible else { return }
            self.findBar?.removeFromSuperview()
            self.findBar = nil
            self.layoutTerminalView()
        }
    }

    func setRecording(_ recording: Bool, forTab tabID: UUID) {
        guard let index = pane.tabs.firstIndex(where: { $0.id == tabID }),
            pane.setRecording(recording, at: index)
        else { return }
        updatePaneControls()
        needsDisplay = true
    }

    /// Stores a tab's progress, redraws, and re-arms its stale timer.
    func setProgress(_ progress: TerminalProgress?, forTab tabID: UUID) {
        guard let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        progressExpiry.removeValue(forKey: tabID)?.cancel()
        if let progress {
            let expiry = DispatchWorkItem { [weak self] in
                guard let self, let index = self.pane.tabs.firstIndex(where: { $0.id == tabID }),
                    self.pane.tabs[index].state.progress?.updatedAt == progress.updatedAt
                else { return }
                self.setProgress(nil, forTab: tabID)
            }
            progressExpiry[tabID] = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + TerminalProgress.staleAfter, execute: expiry)
        }
        guard pane.setProgress(progress, at: index) else { return }
        needsDisplay = true
        paneDelegate?.paneView(self, progressChangedIn: paneID)
    }

    /// Debounce a title update: each new title resets the timer so only the
    /// final value after the burst is applied.
    private func debounceTitleUpdate(_ title: String, tabID: UUID? = nil) {
        // Bind the update to the tab that owns the emitting surface, NOT the
        // active tab at fire time — a late burst from the previous tab must not
        // clobber a freshly-created tab's title.
        guard let capturedTabID = tabID ?? pane.activeTab?.id else { return }
        pendingTitles[capturedTabID] = title
        titleDebounces.removeValue(forKey: capturedTabID)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let title = self.pendingTitles.removeValue(forKey: capturedTabID) else { return }
            self.titleDebounces.removeValue(forKey: capturedTabID)
            guard let resolvedIndex = self.pane.tabs.firstIndex(where: { $0.id == capturedTabID }) else { return }
            self.pane.updateTitle(at: resolvedIndex, title)
            // Every tab, not only the active one: a remote agent in a background tab
            // must still reach the inbox.
            RemoteAgentTracker.shared.titleChanged(
                tabID: capturedTabID, title: title, shellPID: self.pane.tabs[resolvedIndex].shellPID)
            // Only the active tab drives window/bridge title state.
            if resolvedIndex == self.pane.activeTabIndex {
                self.paneDelegate?.paneView(self, titleChanged: title, paneID: self.paneID)
            }
            self.scheduleTabBarRedraw()
        }
        titleDebounces[capturedTabID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Debounce a CWD update: each new path resets the timer so only the
    /// final value after the burst is applied.
    private func debounceCwdUpdate(_ path: String, tabID: UUID? = nil) {
        // Bind to the emitting surface's tab, not the active tab at fire time —
        // same hazard the title path guards against.
        guard let capturedTabID = tabID ?? pane.activeTab?.id else { return }
        pendingCwds[capturedTabID] = path
        cwdDebounces.removeValue(forKey: capturedTabID)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let cwd = self.pendingCwds.removeValue(forKey: capturedTabID) else { return }
            self.cwdDebounces.removeValue(forKey: capturedTabID)
            guard let resolvedIndex = self.pane.tabs.firstIndex(where: { $0.id == capturedTabID }) else { return }
            self.pane.updateWorkingDirectory(at: resolvedIndex, cwd)
            self.scheduleTabBarRedraw()
            // Only the active tab drives the bridge / file explorer CWD.
            if resolvedIndex == self.pane.activeTabIndex {
                self.paneDelegate?.paneView(self, didChangeDirectory: cwd, paneID: self.paneID)
            }
        }
        cwdDebounces[capturedTabID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Coalesce rapid title/cwd updates into a single redraw per run loop cycle.
    private func scheduleTabBarRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.needsDisplay = true
        }
    }
}
