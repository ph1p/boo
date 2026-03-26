import Cocoa
import SwiftUI

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

        let tabState = activeTab?.state ?? TabState(workingDirectory: ws.folderPath, title: "")
        let baseContext = coordinator.buildContext(
            paneID: ws.activePaneID,
            tabID: activeTab?.id,
            tabState: tabState,
            gitContext: buildGitContext(cwd: cwd),
            processName: bridge.state.foregroundProcess,
            paneCount: ws.panes.count,
            tabCount: ws.pane(for: ws.activePaneID)?.tabs.count ?? 1
        )

        // Notify plugins of lifecycle events only when the relevant data changed.
        // This prevents redundant work when the same event fires multiple times
        // (e.g. focus callbacks from sidebar rebuilds).
        let lastCtx = pluginRegistry.lastContext
        if reason == .cwdChanged, cwd != lastCtx?.cwd {
            pluginRegistry.notifyCwdChanged(newPath: cwd, context: baseContext)
        }
        if reason == .focusChanged || reason == .workspaceSwitched {
            // Only notify focus change when the pane actually changed
            if ws.activePaneID != lastFocusedPluginPaneID {
                lastFocusedPluginPaneID = ws.activePaneID
                pluginRegistry.notifyFocusChanged(terminalID: ws.activePaneID, context: baseContext)
            }
        }
        if reason == .remoteSessionChanged, baseContext.remoteSession != lastCtx?.remoteSession {
            pluginRegistry.notifyRemoteSessionChanged(session: activeRemoteSession, context: baseContext)
        }
        let currentProcess = bridge.state.foregroundProcess
        if currentProcess != lastCtx?.processName {
            pluginRegistry.notifyProcessChanged(name: currentProcess, context: baseContext)
        }

        let result = pluginRegistry.runCycle(baseContext: baseContext, reason: reason)

        // Update global store
        AppStore.shared.updateContext(result.context)
        AppStore.shared.updateVisiblePlugins(result.visiblePluginIDs)

        // Feed plugin status bar contents to status bar
        statusBar.pluginStatusBarContents = result.statusBarContents

        // Feed system info segment from plugin cached values (skip if plugin disabled)
        if AppSettings.shared.isPluginEnabled("system-info"),
            let sysPlugin = pluginRegistry.plugin(for: "system-info") as? SystemInfoPlugin
        {
            let tint: NSColor? =
                sysPlugin.memoryUsage > 0.85
                ? .systemRed : (sysPlugin.memoryUsage > 0.7 ? .systemOrange : nil)
            statusBar.systemInfoSegment.updateValues(
                memoryPct: Int(sysPlugin.memoryUsage * 100),
                diskFreeGB: sysPlugin.diskFreeGB,
                cpuPct: Int(sysPlugin.cpuUsage * 100),
                batteryPct: sysPlugin.battery.map { Int($0.level * 100) } ?? -1,
                batteryCharging: sysPlugin.battery?.isCharging ?? false,
                tint: tint
            )
        }

        // Route git state through cycle result
        statusBar.gitChangedCount = result.context.gitContext?.changedFileCount ?? 0
        if let gitCtx = result.context.gitContext {
            if statusBar.gitBranch != gitCtx.branch || statusBar.gitRepoRoot != gitCtx.repoRoot {
                statusBar.gitBranch = gitCtx.branch
                statusBar.gitRepoRoot = gitCtx.repoRoot
                statusBar.needsDisplay = true
            }
        }

        // Update status bar icon availability based on plugin visibility
        let visibleIDs = result.visiblePluginIDs
        for segment in statusBar.rightPlugins + statusBar.leftPlugins {
            if let iconSegment = segment as? PluginIconSegment,
                let panelID = iconSegment.associatedPanelID
            {
                iconSegment.isAvailable = visibleIDs.contains(panelID)
            }
            if let ftIcon = segment as? FileTreeIconSegment {
                ftIcon.isAvailable =
                    visibleIDs.contains("file-tree-local")
                    || visibleIDs.contains("file-tree-remote")
            }
        }

        // Auto-open process-dependent plugins that just became visible
        // (e.g. AI agent panel when claude starts). Only process-gated plugins
        // auto-open — other plugins are managed by the user via default sidebar settings.
        // Match "process.ai", "process.name == 'vim'" etc. but not "!process.ai" which
        // is a negation (Docker uses "!process.ai" to hide during AI sessions).
        if result.visibilityChanged {
            for plugin in pluginRegistry.plugins
            where plugin.manifest.capabilities?.sidebarPanel == true
                && Self.isProcessGated(when: plugin.manifest.when)
                && visibleIDs.contains(plugin.pluginID)
                && !openPluginIDs.contains(plugin.pluginID)
            {
                openPluginIDs.insert(plugin.pluginID)
                expandedPluginIDs.insert(plugin.pluginID)
            }
        }

        // Rebuild stacked sidebar if any open plugins are actually visible
        let effectiveOpenIDs = openPluginIDs.filter { id in
            guard let plugin = pluginRegistry.plugin(for: id) else { return false }
            return plugin.isVisible(for: result.context)
        }
        if !effectiveOpenIDs.isEmpty {
            // Only rebuild sidebar when context or visibility actually changed
            if result.contextChanged || result.visibilityChanged || pluginSidebarPanelView == nil {
                rebuildPluginSidebar(context: result.context)
            }
        } else if sidebarVisible {
            // No visible plugins open — save heights before destroying panel
            if let panel = pluginSidebarPanelView {
                savedSidebarHeights = panel.savedSectionHeights
            }
            pluginSidebarPanelView?.removeFromSuperview()
            pluginSidebarPanelView = nil
            toggleSidebar(userInitiated: false)
        }
        syncStatusBarHighlight()
    }

    /// Build git context from the current CWD.
    /// Uses synchronous detection so it's always accurate, even right after cd into a repo.
    func buildGitContext(cwd: String) -> TerminalContext.GitContext? {
        // Try status bar cache first (fast path), but verify .git still exists
        if let branch = statusBar.gitBranch, let repoRoot = statusBar.gitRepoRoot,
            cwd == repoRoot || cwd.hasPrefix(repoRoot + "/")
        {
            let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir) {
                return TerminalContext.GitContext(
                    branch: branch,
                    repoRoot: repoRoot,
                    isDirty: false,
                    changedFileCount: 0,
                    stagedCount: 0,
                    aheadCount: 0,
                    behindCount: 0,
                    lastCommitShort: nil
                )
            }
            // .git was removed — clear stale cache
            statusBar.gitBranch = nil
            statusBar.gitRepoRoot = nil
            statusBar.needsDisplay = true
        }
        // Synchronous fallback: detect git info directly from the filesystem
        let (branch, repoRoot) = StatusBarView.detectGitInfo(in: cwd)
        guard let branch = branch, let repoRoot = repoRoot else { return nil }
        return TerminalContext.GitContext(
            branch: branch,
            repoRoot: repoRoot,
            isDirty: false,
            changedFileCount: 0,
            stagedCount: 0,
            aheadCount: 0,
            behindCount: 0,
            lastCommitShort: nil
        )
    }

    /// Compute a dynamic section title for a plugin.
    func sectionTitle(for plugin: ExtermPluginProtocol, context: TerminalContext) -> String {
        let pluginCtx = pluginRegistry.buildPluginContext(for: plugin.pluginID, terminal: context)
        if let title = plugin.sectionTitle(context: pluginCtx) {
            return title
        }
        return plugin.manifest.name
    }

    /// Rebuild the stacked plugin sidebar with all open plugins.
    func rebuildPluginSidebar(context: TerminalContext) {
        // Build sections for all open + visible plugins
        var sections: [SidebarSection] = []
        // Order plugins by their position in defaultEnabledPluginIDs (user-configurable order)
        let orderedIDs = AppSettings.shared.defaultEnabledPluginIDs
        let allPluginIDs = openPluginIDs.sorted { a, b in
            let ia = orderedIDs.firstIndex(of: a) ?? Int.max
            let ib = orderedIDs.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }

        for pluginID in allPluginIDs {
            guard openPluginIDs.contains(pluginID),
                let plugin = pluginRegistry.plugin(for: pluginID),
                plugin.isVisible(for: context)
            else {
                continue
            }

            // Reuse cached view if the terminal context hasn't changed for this plugin
            let contentView: AnyView
            let generation: UInt64
            if let cached = cachedDetailViews[pluginID], cached.context == context {
                contentView = cached.view
                generation = pluginViewGeneration[pluginID] ?? 0
            } else {
                let pluginCtx = pluginRegistry.buildPluginContext(for: pluginID, terminal: context)
                guard let fresh = plugin.makeDetailView(context: pluginCtx) else { continue }
                cachedDetailViews[pluginID] = (context: context, view: fresh)
                viewGenerationCounter += 1
                generation = viewGenerationCounter
                pluginViewGeneration[pluginID] = generation
                contentView = fresh
            }

            sections.append(
                SidebarSection(
                    id: pluginID,
                    name: sectionTitle(for: plugin, context: context),
                    icon: plugin.manifest.icon,
                    content: contentView,
                    prefersOuterScrollView: plugin.prefersOuterScrollView,
                    generation: generation
                ))
        }

        let newSectionIDs = sections.map(\.id)

        // Auto-expand when only one plugin is visible
        var expanded = expandedPluginIDs
        if sections.count == 1, let onlyID = sections.first?.id {
            expanded.insert(onlyID)
            expandedPluginIDs.insert(onlyID)
        }

        let toggleHandler: (String) -> Void = { [weak self] id in
            guard let self = self else { return }
            if self.expandedPluginIDs.contains(id) {
                self.expandedPluginIDs.remove(id)
            } else {
                self.expandedPluginIDs.insert(id)
            }
            self.savePluginStateForActiveTab()
            if let ctx = self.pluginRegistry.lastContext {
                self.rebuildPluginSidebar(context: ctx)
            }
        }

        lastSidebarSectionIDs = newSectionIDs

        if let existing = pluginSidebarPanelView {
            existing.onToggleExpand = toggleHandler
            existing.setTerminalID(context.terminalID)
            existing.updateSections(sections, expandedIDs: expanded)
            // Sync heights back to controller
            savedSidebarHeights = existing.savedSectionHeights
        } else {
            let panel = SidebarPanelView(frame: .zero)
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.onToggleExpand = toggleHandler
            panel.setTerminalID(context.terminalID)
            // Restore saved heights from controller
            panel.savedSectionHeights = savedSidebarHeights
            sidebarContainer.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
                panel.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor)
            ])
            panel.updateSections(sections, expandedIDs: expanded)
            pluginSidebarPanelView = panel
        }

        if !sidebarVisible && !sidebarUserHidden {
            toggleSidebar(userInitiated: false)
        }
    }

    /// Persist current global plugin state to the active tab's TabState.
    private func savePluginStateForActiveTab() {
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID)
        else { return }
        pane.updatePluginState(at: pane.activeTabIndex, open: openPluginIDs, expanded: expandedPluginIDs)
    }

    /// Toggle a plugin in/out of the sidebar stack.
    /// Calls lifecycle hooks so plugins can start/stop background work.
    func togglePluginInSidebar(_ pluginID: String) {
        if openPluginIDs.contains(pluginID) {
            openPluginIDs.remove(pluginID)
            expandedPluginIDs.remove(pluginID)
            cachedDetailViews.removeValue(forKey: pluginID)
            pluginRegistry.deactivatePlugin(pluginID)
            AppSettings.shared.updateDefaultEnabledPlugins(remove: pluginID)
        } else {
            openPluginIDs.insert(pluginID)
            pluginRegistry.activatePlugin(pluginID)
            AppSettings.shared.updateDefaultEnabledPlugins(add: pluginID)
        }
        savePluginStateForActiveTab()
        if !hasVisibleOpenPlugins() {
            // No plugins open — save heights, then remove panel
            if let panel = pluginSidebarPanelView {
                savedSidebarHeights = panel.savedSectionHeights
            }
            pluginSidebarPanelView?.removeFromSuperview()
            pluginSidebarPanelView = nil
            if sidebarVisible {
                toggleSidebar(userInitiated: false)
            }
        } else {
            // Show sidebar if hidden — user explicitly opened a plugin
            if !sidebarVisible {
                sidebarUserHidden = false
                toggleSidebar(userInitiated: false)
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

    /// True if the when-clause positively requires a process condition (e.g. "process.ai"),
    /// false if it only negates one (e.g. "!process.ai") or has no process clause.
    static func isProcessGated(when clause: String?) -> Bool {
        guard let clause else { return false }
        // Look for "process." not preceded by "!"
        // Split by "process." and check each occurrence isn't negated
        var search = clause[clause.startIndex...]
        while let range = search.range(of: "process.") {
            let before = range.lowerBound > clause.startIndex
                ? clause[clause.index(before: range.lowerBound)]
                : Character(" ")
            if before != "!" {
                return true
            }
            search = clause[range.upperBound...]
        }
        return false
    }

    func syncStatusBarHighlight() {
        statusBar.visibleSidebarPlugins = openPluginIDs
        statusBar.needsDisplay = true
    }

    /// Find the pane containing a tab with the given ID across all workspaces.
    func findPaneContainingTab(_ tabID: UUID) -> Pane? {
        guard let ws = activeWorkspace else { return nil }
        for pane in ws.panes.values {
            if pane.tabs.contains(where: { $0.id == tabID }) {
                return pane
            }
        }
        return nil
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
