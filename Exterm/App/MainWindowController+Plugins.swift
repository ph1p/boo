import Cocoa

extension MainWindowController {
    func setupPluginWatcher() {
        let watcher = PluginWatcher()
        watcher.registry = pluginRegistry
        watcher.onPluginLoaded = { [weak self] name in
            self?.runPluginCycle(reason: .focusChanged)
        }
        watcher.onPluginRemoved = { [weak self] name in
            self?.runPluginCycle(reason: .focusChanged)
        }
        watcher.start()
        pluginWatcher = watcher
    }

    /// Run the new plugin system cycle and update the sidebar if a detail plugin is active.
    func runPluginCycle(reason: PluginCycleReason) {
        guard let ws = activeWorkspace else { return }
        let activeTab = ws.pane(for: ws.activePaneID)?.activeTab
        let cwd = activeTab?.workingDirectory ?? ws.folderPath
        let remoteSession = activeTab?.remoteSession
        let remoteCwd = activeTab?.remoteWorkingDirectory

        let baseContext = TerminalContext(
            terminalID: ws.activePaneID,
            cwd: cwd,
            remoteSession: remoteSession,
            remoteCwd: remoteCwd,
            gitContext: buildGitContext(cwd: cwd),
            processName: bridge.state.foregroundProcess,
            paneCount: ws.panes.count,
            tabCount: ws.pane(for: ws.activePaneID)?.tabs.count ?? 1
        )

        // Notify plugins of lifecycle events so they can refresh cached state
        switch reason {
        case .cwdChanged:
            pluginRegistry.notifyCwdChanged(newPath: cwd, context: baseContext)
        case .focusChanged, .workspaceSwitched:
            pluginRegistry.notifyFocusChanged(terminalID: ws.activePaneID, context: baseContext)
        case .processChanged:
            pluginRegistry.notifyProcessChanged(name: bridge.state.foregroundProcess, context: baseContext)
        case .remoteSessionChanged:
            pluginRegistry.notifyRemoteSessionChanged(session: activeRemoteSession, context: baseContext)
        case .titleChanged:
            break
        }

        let result = pluginRegistry.runCycle(baseContext: baseContext, reason: reason)

        // On focus/workspace change, save and restore per-pane plugin state
        if reason == .focusChanged || reason == .workspaceSwitched {
            if let prevPane = previousFocusedPaneID {
                paneOpenPlugins[prevPane] = openPluginIDs
                paneExpandedPlugins[prevPane] = expandedPluginIDs
            }
            let newPaneID = ws.activePaneID
            if let restored = paneOpenPlugins[newPaneID] {
                openPluginIDs = restored
                expandedPluginIDs = paneExpandedPlugins[newPaneID] ?? restored
            }
            previousFocusedPaneID = newPaneID
        }

        // Update status bar icon availability based on plugin visibility
        let visibleIDs = result.visiblePluginIDs
        for segment in statusBar.rightPlugins + statusBar.leftPlugins {
            if let iconSegment = segment as? PluginIconSegment,
               let panelID = iconSegment.associatedPanelID {
                iconSegment.isAvailable = visibleIDs.contains(panelID)
            }
        }

        // Rebuild stacked sidebar if any open plugins are actually visible
        let effectiveOpenIDs = openPluginIDs.filter { id in
            guard let plugin = pluginRegistry.plugin(for: id) else { return false }
            return plugin.isVisible(for: result.context)
        }
        if !effectiveOpenIDs.isEmpty {
            rebuildPluginSidebar(context: result.context)
        } else if sidebarVisible {
            // No visible plugins open — auto-hide sidebar
            pluginSidebarPanelView?.removeFromSuperview()
            pluginSidebarPanelView = nil
            toggleSidebarAction(nil)
        }
        syncStatusBarHighlight()
    }

    /// Build git context from the current CWD.
    /// Uses synchronous detection so it's always accurate, even right after cd into a repo.
    func buildGitContext(cwd: String) -> TerminalContext.GitContext? {
        // Try status bar cache first (fast path)
        if let branch = statusBar.gitBranch, let repoRoot = statusBar.gitRepoRoot,
           cwd == repoRoot || cwd.hasPrefix(repoRoot + "/") {
            return TerminalContext.GitContext(
                branch: branch,
                repoRoot: repoRoot,
                isDirty: false,
                changedFileCount: 0
            )
        }
        // Synchronous fallback: detect git info directly from the filesystem
        let (branch, repoRoot) = StatusBarView.detectGitInfo(in: cwd)
        guard let branch = branch, let repoRoot = repoRoot else { return nil }
        return TerminalContext.GitContext(
            branch: branch,
            repoRoot: repoRoot,
            isDirty: false,
            changedFileCount: 0
        )
    }

    /// Compute a dynamic section title for a plugin.
    func sectionTitle(for plugin: ExtermPluginProtocol, context: TerminalContext) -> String {
        if let title = plugin.sectionTitle(context: context) {
            return title
        }
        return plugin.manifest.name
    }

    /// Rebuild the stacked plugin sidebar with all open plugins.
    func rebuildPluginSidebar(context: TerminalContext) {
        let actionHandler = DSLActionHandler()
        actionHandler.sendToTerminal = { [weak self] cmd in
            self?.sendRawToActivePane(cmd)
        }

        // Build sections for all open + visible plugins
        var sections: [SidebarSection] = []
        let orderedIDs = ["file-tree", "git-panel", "docker", "bookmarks"]
        let allPluginIDs = orderedIDs + openPluginIDs.filter { !orderedIDs.contains($0) }.sorted()

        for pluginID in allPluginIDs {
            guard openPluginIDs.contains(pluginID),
                  let plugin = pluginRegistry.plugin(for: pluginID),
                  plugin.isVisible(for: context),
                  let contentView = plugin.makeDetailView(context: context, actionHandler: actionHandler) else {
                continue
            }
            sections.append(SidebarSection(
                id: pluginID,
                name: sectionTitle(for: plugin, context: context),
                icon: plugin.manifest.icon,
                content: contentView,
                prefersOuterScrollView: plugin.prefersOuterScrollView
            ))
        }

        let newSectionIDs = sections.map(\.id)
        let expanded = expandedPluginIDs

        let toggleHandler: (String) -> Void = { [weak self] id in
            guard let self = self else { return }
            if self.expandedPluginIDs.contains(id) {
                self.expandedPluginIDs.remove(id)
            } else {
                self.expandedPluginIDs.insert(id)
            }
            if let ctx = self.pluginRegistry.lastContext {
                self.rebuildPluginSidebar(context: ctx)
            }
        }

        lastSidebarSectionIDs = newSectionIDs

        if let existing = pluginSidebarPanelView {
            existing.onToggleExpand = toggleHandler
            existing.updateSections(sections, expandedIDs: expanded)
        } else {
            let panel = SidebarPanelView(frame: .zero)
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.onToggleExpand = toggleHandler
            sidebarContainer.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
                panel.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            ])
            panel.updateSections(sections, expandedIDs: expanded)
            pluginSidebarPanelView = panel
        }

        if !sidebarVisible {
            toggleSidebarAction(nil)
        }
    }

    /// Toggle a plugin in/out of the sidebar stack.
    func togglePluginInSidebar(_ pluginID: String) {
        if openPluginIDs.contains(pluginID) {
            openPluginIDs.remove(pluginID)
            expandedPluginIDs.remove(pluginID)
        } else {
            openPluginIDs.insert(pluginID)
            expandedPluginIDs.insert(pluginID)
        }
        if !hasVisibleOpenPlugins() {
            // No plugins open — remove hosting view and auto-hide sidebar
            pluginSidebarPanelView?.removeFromSuperview()
            pluginSidebarPanelView = nil
            if sidebarVisible {
                toggleSidebarAction(nil)
            }
        } else {
            // Show sidebar if hidden
            if !sidebarVisible {
                toggleSidebarAction(nil)
            }
            // Rebuild with existing context, or run a fresh cycle
            if let ctx = pluginRegistry.lastContext {
                rebuildPluginSidebar(context: ctx)
            } else {
                runPluginCycle(reason: .focusChanged)
            }
        }
        syncStatusBarHighlight()
    }

    func syncStatusBarHighlight() {
        statusBar.visibleSidebarPlugins = openPluginIDs
        statusBar.needsDisplay = true
    }

    /// Whether any currently-open plugin is actually visible in the current context.
    func hasVisibleOpenPlugins() -> Bool {
        guard let ctx = pluginRegistry.lastContext else { return !openPluginIDs.isEmpty }
        return openPluginIDs.contains { id in
            guard let plugin = pluginRegistry.plugin(for: id) else { return false }
            return plugin.isVisible(for: ctx)
        }
    }
}
