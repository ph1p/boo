import Cocoa
import SwiftUI

// MARK: - Section Options Button

/// Small "···" overlay button shown in the top-right corner of a single-section plugin view
/// when the plugin has hidden sections. Clicking it shows a menu to restore all hidden sections.
final class SectionOptionsButton: NSView {
    var pluginID: String = ""
    var onUnhideAll: (() -> Void)?

    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Show all sections",
            action: #selector(unhideAll),
            keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func unhideAll() { onUnhideAll?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        if isHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        if let img = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Section options") {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                .applying(.init(paletteColors: [theme.chromeMuted.withAlphaComponent(0.7)]))
            if let tinted = img.withSymbolConfiguration(config) {
                let sz = tinted.size
                tinted.draw(
                    in: NSRect(
                        x: (bounds.width - sz.width) / 2,
                        y: (bounds.height - sz.height) / 2,
                        width: sz.width, height: sz.height))
            }
        }
    }
}

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
        watcher.onPluginLoaded = { [weak self] _ in
            guard let self else { return }
            self.runPluginCycle(reason: .focusChanged)
            PluginSettingsView.registeredManifests = self.pluginRegistry.plugins.map(\.manifest)
            NotificationCenter.default.post(
                name: .settingsChanged,
                object: nil,
                userInfo: ["topic": SettingsTopic.plugins.rawValue])
        }
        watcher.onPluginRemoved = { [weak self] _ in
            guard let self else { return }
            self.runPluginCycle(reason: .focusChanged)
            PluginSettingsView.registeredManifests = self.pluginRegistry.plugins.map(\.manifest)
            NotificationCenter.default.post(
                name: .settingsChanged,
                object: nil,
                userInfo: ["topic": SettingsTopic.plugins.rawValue])
        }
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

        // Rebuild tab bar with current context (rebuilds on context/visibility changes)
        if result.contextChanged || result.visibilityChanged || sidebarTabBarView?.sidebarTabs.isEmpty == true {
            rebuildSidebarTabs(context: result.context)
        } else if let active = activePluginTabID {
            refreshActivePluginTab(id: active, context: result.context)
        }

        refreshStatusBar()
    }

    /// Build git context from the current CWD.
    func buildGitContext(cwd: String) -> TerminalContext.GitContext? {
        NSLog(
            "[Git] buildGitContext: cwd=\(cwd) cached=\(statusBar.gitBranch ?? "nil") cachedRoot=\(statusBar.gitRepoRoot ?? "nil")"
        )
        if let branch = statusBar.gitBranch, let repoRoot = statusBar.gitRepoRoot,
            cwd == repoRoot || cwd.hasPrefix(repoRoot + "/")
        {
            let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir) {
                NSLog("[Git] buildGitContext: cache HIT branch=\(branch)")
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
            NSLog("[Git] buildGitContext: .git gone, clearing cache")
            statusBar.gitBranch = nil
            statusBar.gitRepoRoot = nil
            statusBar.needsDisplay = true
        }
        let (branch, repoRoot) = StatusBarView.detectGitInfo(in: cwd)
        NSLog("[Git] buildGitContext: fallback branch=\(branch ?? "nil") repoRoot=\(repoRoot ?? "nil")")
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

        // Apply saved tab order
        let order = AppSettings.shared.sidebarTabOrder
        let sorted = allTabs.sorted { a, b in
            let ia = order.firstIndex(of: a.id.id) ?? Int.max
            let ib = order.firstIndex(of: b.id.id) ?? Int.max
            return ia < ib
        }

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
    /// Reuses the existing panel view when context hasn't changed — only rebuilds on context change.
    /// Single section → full-height content (with scroll view if prefersOuterScrollView).
    /// Multiple sections → SidebarPanelView with collapsible headers.
    func showPluginTabContent(id: String, context: TerminalContext) {
        // If a panel already exists and context hasn't changed, just make it visible
        if let existing = pluginPanelViews[id],
            let cached = cachedDetailViews[id], cached.context == context
        {
            for (otherID, view) in pluginPanelViews where otherID != id {
                view.isHidden = true
            }
            existing.isHidden = false
            return
        }

        guard let plugin = pluginRegistry.plugin(for: id) else { return }
        let pluginCtx = pluginRegistry.buildPluginContext(for: id, terminal: context)

        // Get sections from the plugin's sidebar tab
        guard let sidebarTab = plugin.makeSidebarTab(context: pluginCtx) else { return }
        // Filter out sections the user has hidden (keeping at least one)
        let allSections = sidebarTab.sections
        let visibleSections = allSections.filter { section in
            !AppSettings.shared.pluginBool(id, "hiddenSection_\(section.id)", default: false)
        }
        // Ensure at least one section always shows
        let sections = visibleSections.isEmpty ? allSections : visibleSections
        guard !sections.isEmpty else { return }

        // Cache so future calls with same context skip rebuild
        if let firstSection = sections.first,
            let cached = cachedDetailViews[id], cached.context == context
        {
            _ = firstSection  // context already cached
        } else {
            viewGenerationCounter += 1
            // Store a sentinel — the actual view is inside sections
            cachedDetailViews[id] = (context: context, view: sections[0].content)
        }

        // Remove old panel for this plugin
        pluginPanelViews[id]?.removeFromSuperview()
        pluginPanelViews.removeValue(forKey: id)

        // Hide all other plugin panels
        for (otherID, view) in pluginPanelViews where otherID != id {
            view.isHidden = true
        }

        if sections.count == 1 {
            installSingleSection(sections[0], pluginID: id, totalSectionCount: allSections.count)
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

    /// Install a single-section plugin view, with an outer scroll view when needed.
    /// `totalSectionCount` is the number of sections in the plugin before hidden filtering —
    /// when > 1 some sections are hidden and we show a "···" button to restore them.
    private func installSingleSection(
        _ section: SidebarSection, pluginID: String, totalSectionCount: Int
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

        sidebarContainer.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: sidebarContentTopAnchor),
            container.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: sidebarContentBottomAnchor)
        ])

        // When some sections are hidden (only one visible), show a small "···" button
        // in the top-right corner to allow the user to restore hidden sections.
        if totalSectionCount > 1 {
            let btn = SectionOptionsButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.pluginID = pluginID
            btn.onUnhideAll = { [weak self] in
                guard let self else { return }
                // Clear all hidden section settings for this plugin
                let pattern = "hiddenSection_"
                var dict = AppSettings.shared.pluginSettingsDict(for: pluginID)
                dict = dict.filter { !$0.key.hasPrefix(pattern) }
                AppSettings.shared.setPluginSettingsDict(dict, for: pluginID)
                self.cachedDetailViews.removeValue(forKey: pluginID)
                if let ctx = self.pluginRegistry.lastContext {
                    self.showPluginTabContent(id: pluginID, context: ctx)
                }
            }
            container.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                btn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                btn.widthAnchor.constraint(equalToConstant: 20),
                btn.heightAnchor.constraint(equalToConstant: 20)
            ])
        }

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
        panel.onReorderSections = { newOrder in
            AppSettings.shared.sidebarTabOrder = newOrder
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
        restoreSidebarPanelState(to: panel)
        panel.setTerminalID(context.terminalID)
        panel.updateSections(sections, expandedIDs: expandedPluginIDs)

        sidebarContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: sidebarContentTopAnchor),
            panel.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: sidebarContentBottomAnchor)
        ])
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
