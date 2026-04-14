import Cocoa
import SwiftUI

// MARK: - Plugin Scroll View

/// NSScrollView that pins document content to the top (flipped clip view).
/// Used in the sidebar for single-section plugins that need outer scrolling.
final class PluginScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        contentView = clip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }
}

extension MainWindowController {
    func remapSidebarScrollOffsets(
        _ offsets: [String: CGPoint],
        from sourceTerminalID: UUID,
        to targetTerminalID: UUID
    ) -> [String: CGPoint] {
        let sourcePrefix = "\(sourceTerminalID.uuidString):"
        let targetPrefix = "\(targetTerminalID.uuidString):"

        var remapped: [String: CGPoint] = [:]
        for (key, value) in offsets where key.hasPrefix(sourcePrefix) {
            let suffix = String(key.dropFirst(sourcePrefix.count))
            remapped[targetPrefix + suffix] = value
        }
        return remapped
    }

    func syncSidebarPanelStateFromView() {
        guard let activeTabID = activePluginTabID,
            let panel = pluginPanelViews[activeTabID] as? SidebarPanelView
        else { return }
        panel.capturePersistentState()
        savedSidebarHeights = panel.savedSectionHeights
        if let terminalID = panel.currentTerminalID {
            let prefix = "\(terminalID.uuidString):"
            savedSidebarScrollOffsets = panel.savedScrollOffsetsSnapshot.filter {
                $0.key.hasPrefix(prefix)
            }
        }
    }

    private func restoreSidebarPanelState(to panel: SidebarPanelView) {
        panel.savedSectionHeights = savedSidebarHeights
        panel.savedScrollOffsetsSnapshot = savedSidebarScrollOffsets
    }

    func setupPluginWatcher() {
        let watcher = PluginWatcher()
        watcher.registry = pluginRegistry
        let handlePluginChange: (String) -> Void = { [weak self] _ in
            guard let self else { return }
            self.runPluginCycle(reason: .focusChanged)
            self.rebuildPluginsMenu()
            PluginSettingsView.registeredManifests = self.pluginRegistry.plugins.map(\.manifest)
            NotificationCenter.default.post(
                name: .settingsChanged,
                object: nil,
                userInfo: ["topic": SettingsTopic.plugins.rawValue])
        }
        watcher.onPluginLoaded = handlePluginChange
        watcher.onPluginRemoved = handlePluginChange
        watcher.start()
        pluginWatcher = watcher
    }

    /// Run the new plugin system cycle and update the sidebar.
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
        let lastCtx = pluginRegistry.lastContext
        if reason == .cwdChanged, cwd != lastCtx?.cwd {
            pluginRegistry.notifyCwdChanged(newPath: cwd, context: baseContext)
        }
        if reason == .focusChanged || reason == .workspaceSwitched {
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

        // Feed plugin status bar contents to status bar (only external plugins get segments)
        statusBar.externalPluginIDs = Set(
            pluginRegistry.plugins.compactMap { $0.manifest.isExternal ? $0.pluginID : nil })
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

        // Rebuild tab bar with current context (rebuilds on context/visibility changes)
        if result.contextChanged || result.visibilityChanged || sidebarTabBarView?.sidebarTabs.isEmpty == true {
            rebuildSidebarTabs(context: result.context)
        } else if let active = activePluginTabID {
            refreshActivePluginTab(id: active, context: result.context)
        }

        if result.visibilityChanged {
            // Activate/deactivate plugins that have no sidebar tab (statusbar-only).
            let sidebarTabIDs = Set(
                pluginRegistry.contributedSidebarTabs(terminal: result.context).map(\.id.id))
            pluginRegistry.reconcileSidebarlessPlugins(
                visibleIDs: result.visiblePluginIDs, sidebarTabIDs: sidebarTabIDs)

            rebuildPluginsMenu()
        }

        refreshStatusBar()
    }

    /// Build git context from the current CWD.
    func buildGitContext(cwd: String) -> TerminalContext.GitContext? {
        booLog(
            .debug, .git,
            "buildGitContext: cwd=\(cwd) cached=\(statusBar.gitBranch ?? "nil") cachedRoot=\(statusBar.gitRepoRoot ?? "nil")"
        )
        if let branch = statusBar.gitBranch, let repoRoot = statusBar.gitRepoRoot,
            cwd == repoRoot || cwd.hasPrefix(repoRoot + "/")
        {
            let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir) {
                booLog(.debug, .git, "buildGitContext: cache HIT branch=\(branch)")
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
            booLog(.debug, .git, "buildGitContext: .git gone, clearing cache")
            statusBar.gitBranch = nil
            statusBar.gitRepoRoot = nil
            statusBar.needsDisplay = true
        }
        let (branch, repoRoot) = StatusBarView.detectGitInfo(in: cwd)
        booLog(.debug, .git, "buildGitContext: fallback branch=\(branch ?? "nil") repoRoot=\(repoRoot ?? "nil")")
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

    // MARK: - Tab-Per-Plugin Sidebar

    /// Top anchor for sidebar content views — below the tab bar (top) or at container top (bottom bar).
    var sidebarContentTopAnchor: NSLayoutYAxisAnchor {
        AppSettings.shared.sidebarTabBarPosition == .bottom
            ? sidebarContainer.topAnchor
            : (sidebarTabBarView?.bottomAnchor ?? sidebarContainer.topAnchor)
    }

    /// Bottom anchor for sidebar content views — above the tab bar (bottom) or at container bottom (top bar).
    var sidebarContentBottomAnchor: NSLayoutYAxisAnchor {
        AppSettings.shared.sidebarTabBarPosition == .bottom
            ? (sidebarTabBarView?.topAnchor ?? sidebarContainer.bottomAnchor)
            : sidebarContainer.bottomAnchor
    }

    /// Collect plugin-contributed tabs and push them to the tab bar.
    /// Shows sidebar if tabs exist and it's not user-hidden.
    func rebuildSidebarTabs(context: TerminalContext) {
        // Collect all enabled+visible plugin tabs
        let allTabs = pluginRegistry.contributedSidebarTabs(terminal: context)

        // Apply saved tab order (tabs missing from saved order keep their
        // registration position instead of jumping to the end).
        let sorted = SidebarTabOrdering.applied(
            tabs: allTabs,
            savedOrder: AppSettings.shared.sidebarTabOrder)

        sidebarTabBarView?.sidebarTabs = sorted

        if sorted.isEmpty {
            // No tabs — collapse sidebar
            activePluginTabID = nil
            removeAllPluginContent()
            if sidebarVisible { toggleSidebar(userInitiated: false) }
        } else if let activeID = activePluginTabID,
            let activeTab = sorted.first(where: { $0.id.id == activeID })
        {
            // Active tab still present — if no panel exists yet (e.g. session restore on
            // startup), run the full activation so pluginDidActivate() is called and the
            // plugin can start background work before its content is shown.
            if pluginPanelViews[activeID] == nil {
                activatePluginTab(activeTab.id, context: context)
            } else {
                sidebarTabBarView?.selectedTab = activeTab.id
                sidebarTabBarView?.needsDisplay = true
                refreshActivePluginTab(id: activeID, context: context)
                // Ensure sidebar is visible
                if !sidebarVisible && !sidebarUserHidden {
                    toggleSidebar(userInitiated: false)
                }
            }
        } else {
            // No active tab or active tab disappeared — activate the first available,
            // preferring the last-selected tab restored from session state.
            let target =
                activePluginTabID.flatMap { id in sorted.first(where: { $0.id.id == id }) }
                ?? coordinator.selectedPluginTabID.flatMap { id in
                    sorted.first(where: { $0.id.id == id })
                }
                ?? sorted.first
            if let tab = target {
                activatePluginTab(tab.id, context: context)
            }
        }
    }

    /// Activate a plugin tab: deactivate old, show content, activate new.
    func activatePluginTab(_ tabID: SidebarTabID, context: TerminalContext) {
        if let old = activePluginTabID, old != tabID.id {
            pluginRegistry.deactivatePlugin(old)
        }
        activePluginTabID = tabID.id
        coordinator.selectedPluginTabID = tabID.id
        sidebarTabBarView?.selectedTab = tabID
        sidebarTabBarView?.needsDisplay = true

        showPluginTabContent(id: tabID.id, context: context)
        pluginRegistry.activatePlugin(tabID.id)

        if !sidebarVisible && !sidebarUserHidden {
            toggleSidebar(userInitiated: false)
        }
    }

    /// Refresh the currently active plugin tab's content without changing selection.
    private func refreshActivePluginTab(id: String, context: TerminalContext) {
        showPluginTabContent(id: id, context: context)
    }

    /// Show content for the given plugin tab ID in the sidebar container.
    /// Always calls makeSidebarTab() to get fresh data, but reuses view when context and generations match.
    /// Single section → full-height content (with scroll view if prefersOuterScrollView).
    /// Multiple sections → SidebarPanelView with collapsible headers.
    func showPluginTabContent(id: String, context: TerminalContext) {
        guard let plugin = pluginRegistry.plugin(for: id) else { return }
        let pluginCtx = pluginRegistry.buildPluginContext(for: id, terminal: context)

        // Always call makeSidebarTab to get fresh data from the plugin
        guard let sidebarTab = plugin.makeSidebarTab(context: pluginCtx) else { return }

        // Filter out sections the user has hidden (keeping at least one)
        let allSections = sidebarTab.sections
        let visibleSections = allSections.filter { section in
            !AppSettings.shared.pluginBool(id, "hiddenSection_\(section.id)", default: false)
        }
        // Ensure at least one section always shows
        let filteredSections = visibleSections.isEmpty ? allSections : visibleSections
        // Apply saved section order
        let sectionOrder = savedSidebarSectionOrder[id] ?? []
        let sections = filteredSections.sorted { a, b in
            let ia = sectionOrder.firstIndex(of: a.id) ?? Int.max
            let ib = sectionOrder.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
        guard !sections.isEmpty else { return }

        // Check if we can reuse the cached panel (same context AND same generations)
        let newGenerations = sections.map { $0.generation }
        if let existing = pluginPanelViews[id],
            let cached = cachedDetailViews[id],
            cached.context == context,
            cached.generations == newGenerations
        {
            for (otherID, view) in pluginPanelViews where otherID != id {
                view.isHidden = true
            }
            existing.isHidden = false
            return
        }

        // Cache with generations so we detect data changes
        viewGenerationCounter += 1
        cachedDetailViews[id] = (context: context, generations: newGenerations, view: sections[0].content)

        // Remove old panel for this plugin
        pluginPanelViews[id]?.removeFromSuperview()
        pluginPanelViews.removeValue(forKey: id)

        // Hide all other plugin panels
        for (otherID, view) in pluginPanelViews where otherID != id {
            view.isHidden = true
        }

        if sections.count == 1 {
            installSingleSection(sections[0], pluginID: id)
        } else {
            // Auto-expand the first section unless the user has explicitly collapsed it.
            if let firstID = sections.first?.id,
                !expandedPluginIDs.contains(firstID),
                !userCollapsedSectionIDs.contains(firstID)
            {
                expandedPluginIDs.insert(firstID)
            }
            installMultiSection(sections, pluginID: id, context: context)
        }
    }

    /// Install a single-section plugin view with an outer scroll view.
    private func installSingleSection(
        _ section: SidebarSection, pluginID: String
    ) {
        let container: NSView
        // maxWidth: .infinity fills the hosting view width.
        // maxHeight: .infinity + topLeading pins content to the top when the hosting
        // view is stretched taller than the content by the greaterThanOrEqualTo constraint.
        let contentView = AnyView(
            section.content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )

        // sizingOptions = [.intrinsicContentSize] lets Auto Layout see the SwiftUI
        // content's natural height so the document view grows to fit tall content
        // and the scroll view can actually scroll.
        // The greaterThanOrEqualTo height constraint ensures short content fills
        // the viewport (top-pinned) rather than collapsing to zero.
        let hosting = NSHostingView(rootView: contentView)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = PluginScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])
        container = scrollView

        let edgePad: CGFloat = 2
        sidebarContainer.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: sidebarContentTopAnchor, constant: edgePad),
            container.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: sidebarContentBottomAnchor, constant: -edgePad)
        ])

        pluginPanelViews[pluginID] = container
    }

    /// Install a multi-section plugin view using SidebarPanelView with collapsible headers.
    private func installMultiSection(_ sections: [SidebarSection], pluginID: String, context: TerminalContext) {
        let toggleHandler: (String) -> Void = { [weak self] sectionID in
            guard let self else { return }
            if self.expandedPluginIDs.contains(sectionID) {
                // User is explicitly collapsing — record it so auto-expand won't fight them.
                self.expandedPluginIDs.remove(sectionID)
                self.userCollapsedSectionIDs.insert(sectionID)
            } else {
                // User is explicitly expanding — clear any prior collapse record.
                self.expandedPluginIDs.insert(sectionID)
                self.userCollapsedSectionIDs.remove(sectionID)
            }
            self.savePluginStateForActiveTab()
            // Force rebuild next cycle
            self.cachedDetailViews.removeValue(forKey: pluginID)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginTabContent(id: pluginID, context: ctx)
            }
        }

        let panel = SidebarPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onToggleExpand = toggleHandler
        panel.onReorderSections = { [weak self] newOrder in
            guard let self else { return }
            self.savedSidebarSectionOrder[pluginID] = newOrder
            self.cachedDetailViews.removeValue(forKey: pluginID)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginTabContent(id: pluginID, context: ctx)
            }
        }
        panel.onHideSection = { [weak self] sectionID in
            guard let self else { return }
            AppSettings.shared.setPluginSetting(
                pluginID, "hiddenSection_\(sectionID)", true, topic: nil)
            self.cachedDetailViews.removeValue(forKey: pluginID)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginTabContent(id: pluginID, context: ctx)
            }
        }
        panel.onDragEnded = { [weak self] in
            // Persist heights to Settings when resize drag ends
            self?.syncSidebarPanelStateFromView()
            self?.coordinator?.saveSidebarStateToSettings()
        }
        restoreSidebarPanelState(to: panel)
        panel.setTerminalID(context.terminalID)

        sidebarContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: sidebarContentTopAnchor),
            panel.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: sidebarContentBottomAnchor)
        ])
        sidebarContainer.layoutSubtreeIfNeeded()
        panel.updateSections(sections, expandedIDs: expandedPluginIDs)
        pluginPanelViews[pluginID] = panel
    }

    /// Remove all plugin content views from the sidebar container.
    func removeAllPluginContent() {
        for (_, view) in pluginPanelViews {
            view.removeFromSuperview()
        }
        pluginPanelViews.removeAll()
    }

    /// Persist current global plugin state to the active tab's TabState.
    /// When sidebar global state is enabled, still syncs in-memory coordinator state
    /// from the live panel (so heights stay current) but skips writing to TabState.
    func savePluginStateForActiveTab() {
        syncSidebarPanelStateFromView()
        guard !AppSettings.shared.sidebarGlobalState else { return }
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID)
        else { return }
        pane.updatePluginState(
            at: pane.activeTabIndex,
            expanded: expandedPluginIDs,
            userCollapsed: userCollapsedSectionIDs,
            sidebarSectionHeights: savedSidebarHeights,
            sidebarScrollOffsets: savedSidebarScrollOffsets,
            sidebarSectionOrder: savedSidebarSectionOrder,
            selectedPluginTabID: activePluginTabID
        )
    }

    /// True if the when-clause positively requires a process condition (e.g. "process.ai"),
    /// false if it only negates one (e.g. "!process.ai") or has no process clause.
    static func isProcessGated(when clause: String?) -> Bool {
        guard let clause else { return false }
        var search = clause[clause.startIndex...]
        while let range = search.range(of: "process.") {
            let before =
                range.lowerBound > clause.startIndex
                ? clause[clause.index(before: range.lowerBound)]
                : Character(" ")
            if before != "!" {
                return true
            }
            search = clause[range.upperBound...]
        }
        return false
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

    func findTab(_ tabID: UUID) -> Pane.Tab? {
        findPaneContainingTab(tabID)?.tabs.first { $0.id == tabID }
    }
}
