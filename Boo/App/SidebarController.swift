import Cocoa
import SwiftUI

/// Controller responsible for sidebar panel management, plugin tab selection,
/// section heights, and scroll offset persistence.
///
/// Extracted from MainWindowController to achieve single-responsibility.
/// Coordinates with WindowStateCoordinator for state persistence.
@MainActor
final class SidebarController {
    private static let globalScrollOffsetPrefix = "__global__:"

    // MARK: - Dependencies

    weak var windowController: MainWindowController?
    private var coordinator: WindowStateCoordinator {
        guard let wc = windowController else {
            fatalError("SidebarController accessed after windowController was deallocated")
        }
        return wc.coordinator
    }
    private var pluginRegistry: PluginRegistry { coordinator.pluginRegistry }

    // MARK: - UI Components

    /// Container view holding sidebar content and tab bar.
    var sidebarContainer: NSView!

    /// Tab bar for switching between plugin tabs.
    var sidebarTabBarView: SidebarTabBarView?

    /// Active constraints for tab bar position (top/bottom).
    var sidebarTabBarPositionConstraints: [NSLayoutConstraint] = []

    /// One panel view per plugin tab — keyed by plugin ID.
    var pluginPanelViews: [String: NSView] = [:]

    // MARK: - State

    /// Currently active plugin tab ID.
    var activePluginTabID: String?

    /// Cached detail views per plugin, reused when context and generations match.
    var cachedDetailViews: [String: (context: TerminalContext, generations: [UInt64], view: AnyView)] = [:]

    /// Generation counter per plugin — incremented only when the view is recreated.
    var pluginViewGeneration: [String: UInt64] = [:]

    /// Monotonic counter for assigning generations.
    var viewGenerationCounter: UInt64 = 0

    // MARK: - Visibility

    /// Whether the sidebar is currently visible.
    var isVisible: Bool = false

    /// True when the user explicitly hid the sidebar (Cmd+B).
    /// Prevents plugin cycle from auto-showing on tab switch.
    var isUserHidden: Bool = false

    /// Current sidebar position (left/right).
    var position: SidebarPosition = .right
    /// Last intended visible width. This is the canonical width while hidden or restoring.
    private var intendedVisibleWidth: CGFloat?

    // MARK: - Computed State Accessors

    /// Expanded plugin section IDs.
    var expandedPluginIDs: Set<String> {
        get { coordinator.expandedPluginIDs }
        set { coordinator.expandedPluginIDs = newValue }
    }

    /// Section IDs the user has explicitly collapsed.
    var userCollapsedSectionIDs: Set<String> {
        get { coordinator.userCollapsedSectionIDs }
        set { coordinator.userCollapsedSectionIDs = newValue }
    }

    /// Persisted sidebar section heights.
    var savedSectionHeights: [String: CGFloat] {
        get { coordinator.sidebarSectionHeights }
        set { coordinator.sidebarSectionHeights = newValue }
    }

    /// Persisted sidebar scroll offsets.
    var savedScrollOffsets: [String: CGPoint] {
        get { coordinator.sidebarScrollOffsets }
        set { coordinator.sidebarScrollOffsets = newValue }
    }

    /// Persisted sidebar section order per plugin.
    var savedSectionOrder: [String: [String]] {
        get { coordinator.sidebarSectionOrder }
        set { coordinator.sidebarSectionOrder = newValue }
    }

    // MARK: - Initialization

    init(windowController: MainWindowController) {
        self.windowController = windowController
        self.isVisible = !AppSettings.shared.sidebarDefaultHidden
        self.isUserHidden = AppSettings.shared.sidebarDefaultHidden
        self.position = AppSettings.shared.sidebarPosition
        self.intendedVisibleWidth = AppSettings.shared.sidebarWidth
    }

    // MARK: - Setup

    /// Create and configure the sidebar container and tab bar.
    func setupSidebarContainer(in parentView: NSView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor

        // Create tab bar
        let tabBar = SidebarTabBarView(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] tabID in
            guard let self, let ctx = self.pluginRegistry.lastContext else { return }
            self.activatePluginTab(tabID, context: ctx)
        }
        tabBar.onTabDisabled = { [weak self] tabID in
            var disabled = AppSettings.shared.disabledPluginIDs
            if !disabled.contains(tabID.id) {
                disabled.append(tabID.id)
                AppSettings.shared.disabledPluginIDs = disabled
            }
            self?.clearCachedViews()
            if let ctx = self?.pluginRegistry.lastContext {
                self?.rebuildTabs(context: ctx)
            }
        }
        tabBar.onToggleSection = { [weak self] tabID, sectionID in
            self?.handleSectionToggle(pluginID: tabID.id, sectionID: sectionID)
        }
        tabBar.onTabsReordered = { newOrder in
            AppSettings.shared.sidebarTabOrder = SidebarTabOrdering.mergeOrder(
                saved: AppSettings.shared.sidebarTabOrder,
                visible: newOrder.map(\.id))
        }

        container.addSubview(tabBar)
        sidebarTabBarView = tabBar

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: SidebarTabBarView.height)
        ])

        applyTabBarPositionConstraints()

        sidebarContainer = container
        return container
    }

    // MARK: - Tab Bar Position

    /// Apply constraints for tab bar position (top/bottom).
    func applyTabBarPositionConstraints() {
        guard let tabBar = sidebarTabBarView, let container = sidebarContainer else { return }
        NSLayoutConstraint.deactivate(sidebarTabBarPositionConstraints)

        if AppSettings.shared.sidebarTabBarPosition == .bottom {
            sidebarTabBarPositionConstraints = [
                tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ]
        } else {
            sidebarTabBarPositionConstraints = [
                tabBar.topAnchor.constraint(equalTo: container.topAnchor)
            ]
        }
        NSLayoutConstraint.activate(sidebarTabBarPositionConstraints)
    }

    // MARK: - Content Anchors

    /// Top anchor for sidebar content views.
    var contentTopAnchor: NSLayoutYAxisAnchor {
        guard let container = sidebarContainer else { return sidebarContainer.topAnchor }
        return AppSettings.shared.sidebarTabBarPosition == .bottom
            ? container.topAnchor
            : (sidebarTabBarView?.bottomAnchor ?? container.topAnchor)
    }

    /// Bottom anchor for sidebar content views.
    var contentBottomAnchor: NSLayoutYAxisAnchor {
        guard let container = sidebarContainer else { return sidebarContainer.bottomAnchor }
        return AppSettings.shared.sidebarTabBarPosition == .bottom
            ? (sidebarTabBarView?.topAnchor ?? container.bottomAnchor)
            : container.bottomAnchor
    }

    // MARK: - Visibility

    /// Capture current sidebar visibility and intended width into a SidebarWorkspaceState.
    func captureLiveState() -> SidebarWorkspaceState {
        let fallbackState = resolveEffectiveSidebarState()
        let width: CGFloat = {
            if isVisible,
                let renderedWidth = currentRenderedSidebarWidth()
            {
                intendedVisibleWidth = renderedWidth
                return renderedWidth
            }
            return intendedVisibleWidth ?? fallbackState.width ?? AppSettings.shared.sidebarWidth
        }()

        return SidebarWorkspaceState(isVisible: isVisible, width: width)
    }

    /// Apply restored sidebar visibility and width without persisting transient layout state.
    func applyRestoredState(_ state: SidebarWorkspaceState) {
        let resolvedState = resolvedRestoredState(from: state)
        let visible = resolvedState.isVisible ?? isVisible
        let width = resolvedState.width ?? intendedVisibleWidth ?? AppSettings.shared.sidebarWidth
        intendedVisibleWidth = width
        isUserHidden = !visible
        setVisibility(visible, desiredWidth: width, userInitiated: false, persist: false)
    }

    /// Toggle sidebar visibility.
    /// - Parameter userInitiated: Whether the user explicitly toggled (prevents auto-show).
    func toggle(userInitiated: Bool) {
        // Don't allow showing when no tabs available
        if !isVisible && sidebarTabBarView?.sidebarTabs.isEmpty == true {
            return
        }
        let desiredWidth =
            intendedVisibleWidth ?? resolveEffectiveSidebarState().width ?? AppSettings.shared.sidebarWidth
        setVisibility(!isVisible, desiredWidth: desiredWidth, userInitiated: userInitiated, persist: true)
    }

    private func applySidebarWidth(_ width: CGFloat) {
        guard isVisible, let wc = windowController, wc.mainSplitView.subviews.count >= 2 else { return }
        wc.mainSplitView.layoutSubtreeIfNeeded()
        intendedVisibleWidth = width
        let renderedWidth = SidebarStateResolver.normalizedWidth(
            width,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
        let pos = SidebarStateResolver.dividerPosition(
            forSidebarWidth: renderedWidth,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
        wc.mainSplitView.setPosition(pos, ofDividerAt: 0)
    }

    func syncWorkspaceSidebarState() {
        persistLiveState()
    }

    func restoreActiveWorkspaceWidth() {
        let state = resolveEffectiveSidebarState()
        if state.isVisible ?? isVisible {
            applyRestoredState(state)
        }
    }

    func resolveEffectiveSidebarState(for workspace: Workspace? = nil) -> SidebarWorkspaceState {
        SidebarStateResolver.effectiveState(
            workspaceState: (workspace ?? windowController?.activeWorkspace)?.sidebarState,
            environment: stateEnvironment()
        )
    }

    @discardableResult
    func persistLiveState(for workspace: Workspace? = nil) -> SidebarWorkspaceState {
        let capturedState = captureLiveState()
        return persistResolvedState(capturedState, for: workspace)
    }

    @discardableResult
    func persistResolvedState(_ state: SidebarWorkspaceState, for workspace: Workspace? = nil) -> SidebarWorkspaceState
    {
        let target = SidebarStateResolver.persistenceTarget(
            usesPerWorkspaceState: AppSettings.shared.sidebarPerWorkspaceState
        )

        switch target {
        case .workspace:
            (workspace ?? windowController?.activeWorkspace)?.sidebarState = state
        case .appSettings:
            let persistToSettings = { [state] in
                if let isVisible = state.isVisible {
                    let hidden = !isVisible
                    if AppSettings.shared.sidebarDefaultHidden != hidden {
                        AppSettings.shared.sidebarDefaultHidden = hidden
                    }
                }
                if let width = state.width,
                    abs(AppSettings.shared.sidebarWidth - width) > 0.001
                {
                    AppSettings.shared.sidebarWidth = width
                }
            }
            if let windowController {
                windowController.performWhileIgnoringSidebarLayoutSettingsRefresh {
                    persistToSettings()
                }
            } else {
                persistToSettings()
            }
        }

        return state
    }

    private func resolvedRestoredState(from state: SidebarWorkspaceState) -> SidebarWorkspaceState {
        let effectiveState = SidebarWorkspaceState(
            isVisible: state.isVisible ?? resolveEffectiveSidebarState().isVisible,
            width: state.width ?? resolveEffectiveSidebarState().width ?? intendedVisibleWidth
        )
        return SidebarStateResolver.renderedState(
            from: effectiveState,
            environment: stateEnvironment()
        )
    }

    private func stateEnvironment(splitViewWidth: CGFloat? = nil) -> SidebarStateEnvironment {
        SidebarStateEnvironment(
            defaultState: Workspace.defaultSidebarState(),
            usesPerWorkspaceState: AppSettings.shared.sidebarPerWorkspaceState,
            position: position,
            splitViewWidth: splitViewWidth ?? windowController?.mainSplitView.bounds.width,
            dividerThickness: windowController?.mainSplitView.dividerThickness ?? 1,
            backingScaleFactor: windowController?.window?.backingScaleFactor
                ?? windowController?.mainSplitView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
    }

    private func currentRenderedSidebarWidth() -> CGFloat? {
        guard let wc = windowController else { return nil }
        let idx = position == .left ? 0 : 1
        guard idx < wc.mainSplitView.subviews.count else { return nil }
        return SidebarStateResolver.normalizedWidth(
            wc.mainSplitView.subviews[idx].frame.width,
            environment: stateEnvironment(splitViewWidth: wc.mainSplitView.bounds.width)
        )
    }

    private func setVisibility(
        _ visible: Bool,
        desiredWidth: CGFloat,
        userInitiated: Bool,
        persist: Bool
    ) {
        guard let wc = windowController else { return }

        if userInitiated {
            isUserHidden = !visible
        }
        intendedVisibleWidth = desiredWidth

        if isVisible != visible {
            isVisible = visible
            if visible {
                if position == .left {
                    wc.mainSplitView.subviews.insert(sidebarContainer, at: 0)
                } else {
                    wc.mainSplitView.addSubview(sidebarContainer)
                }
                wc.mainSplitView.adjustSubviews()
            } else {
                sidebarContainer.removeFromSuperview()
            }
        }

        if visible {
            applySidebarWidth(desiredWidth)
            DispatchQueue.main.async { [weak self] in
                self?.applySidebarWidth(desiredWidth)
            }
        }

        wc.statusBar.sidebarVisible = isVisible
        AppStore.shared.sidebarVisible = isVisible
        wc.statusBar.needsDisplay = true
        wc.refreshToolbar()

        for (_, pv) in wc.paneViews {
            pv.currentTerminalView?.needsDisplay = true
            pv.currentTerminalView?.needsLayout = true
        }

        if persist {
            persistLiveState()
        }
    }

    // MARK: - Tab Management

    /// Collect plugin-contributed tabs and rebuild the tab bar.
    func rebuildTabs(context: TerminalContext) {
        let allTabs = pluginRegistry.contributedSidebarTabs(terminal: context)

        // Apply saved tab order
        let sorted = SidebarTabOrdering.applied(
            tabs: allTabs,
            savedOrder: AppSettings.shared.sidebarTabOrder)

        sidebarTabBarView?.sidebarTabs = sorted

        if sorted.isEmpty {
            // No tabs — collapse sidebar
            activePluginTabID = nil
            removeAllContent()
            if isVisible { toggle(userInitiated: false) }
        } else if let activeID = activePluginTabID,
            let activeTab = sorted.first(where: { $0.id.id == activeID })
        {
            // Active tab still present
            if pluginPanelViews[activeID] == nil {
                activatePluginTab(activeTab.id, context: context)
            } else {
                sidebarTabBarView?.selectedTab = activeTab.id
                sidebarTabBarView?.needsDisplay = true
                refreshActiveTab(id: activeID, context: context)
                if !isVisible && !isUserHidden {
                    toggle(userInitiated: false)
                }
            }
        } else {
            // Activate first available or last-selected tab
            let target =
                activePluginTabID.flatMap { id in sorted.first(where: { $0.id.id == id }) }
                ?? coordinator.selectedPluginTabID.flatMap { id in sorted.first(where: { $0.id.id == id }) }
                ?? sorted.first
            if let tab = target {
                activatePluginTab(tab.id, context: context)
            }
        }
    }

    /// Activate a plugin tab.
    func activatePluginTab(_ tabID: SidebarTabID, context: TerminalContext) {
        if let old = activePluginTabID, old != tabID.id {
            pluginRegistry.deactivatePlugin(old)
        }
        activePluginTabID = tabID.id
        coordinator.selectedPluginTabID = tabID.id
        sidebarTabBarView?.selectedTab = tabID
        sidebarTabBarView?.needsDisplay = true

        showPluginContent(id: tabID.id, context: context)
        pluginRegistry.activatePlugin(tabID.id)

        if !isVisible && !isUserHidden {
            toggle(userInitiated: false)
        }
    }

    /// Refresh the active plugin tab's content.
    private func refreshActiveTab(id: String, context: TerminalContext) {
        showPluginContent(id: id, context: context)
    }

    // MARK: - Content Display

    /// Show content for the given plugin tab ID.
    func showPluginContent(id: String, context: TerminalContext) {
        guard let plugin = pluginRegistry.plugin(for: id) else { return }
        let pluginCtx = pluginRegistry.buildPluginContext(for: id, terminal: context)

        guard let sidebarTab = plugin.makeSidebarTab(context: pluginCtx) else { return }

        // Filter hidden sections
        let allSections = sidebarTab.sections
        let visibleSections = allSections.filter { section in
            !AppSettings.shared.pluginBool(id, "hiddenSection_\(section.id)", default: false)
        }
        let filteredSections = visibleSections.isEmpty ? allSections : visibleSections

        // Apply saved section order
        let sectionOrder = savedSectionOrder[id] ?? []
        let sections = filteredSections.sorted { a, b in
            let ia = sectionOrder.firstIndex(of: a.id) ?? Int.max
            let ib = sectionOrder.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
        guard !sections.isEmpty else { return }

        // Check cache
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

        // Update cache
        viewGenerationCounter += 1
        cachedDetailViews[id] = (context: context, generations: newGenerations, view: sections[0].content)

        // Remove old panel
        pluginPanelViews[id]?.removeFromSuperview()
        pluginPanelViews.removeValue(forKey: id)

        // Hide other panels
        for (otherID, view) in pluginPanelViews where otherID != id {
            view.isHidden = true
        }

        // Install new content
        if sections.count == 1 {
            installSingleSection(sections[0], pluginID: id)
        } else {
            // Auto-expand first section unless user collapsed it
            if let firstID = sections.first?.id,
                !expandedPluginIDs.contains(firstID),
                !userCollapsedSectionIDs.contains(firstID)
            {
                expandedPluginIDs.insert(firstID)
            }
            installMultiSection(sections, pluginID: id, context: context)
        }
    }

    /// Install a single-section plugin view with outer scroll view.
    private func installSingleSection(_ section: SidebarSection, pluginID: String) {
        guard let container = sidebarContainer else { return }

        let contentView = AnyView(
            section.content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )

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

        let edgePad: CGFloat = 2
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentTopAnchor, constant: edgePad),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentBottomAnchor, constant: -edgePad)
        ])

        pluginPanelViews[pluginID] = scrollView
    }

    /// Install a multi-section plugin view using SidebarPanelView.
    private func installMultiSection(_ sections: [SidebarSection], pluginID: String, context: TerminalContext) {
        guard let container = sidebarContainer else { return }

        let toggleHandler: (String) -> Void = { [weak self] sectionID in
            self?.handleSectionToggle(pluginID: pluginID, sectionID: sectionID)
        }

        let panel = SidebarPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onToggleExpand = toggleHandler
        panel.onReorderSections = { [weak self] newOrder in
            guard let self else { return }
            self.savedSectionOrder[pluginID] = newOrder
            self.cachedDetailViews.removeValue(forKey: pluginID)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginContent(id: pluginID, context: ctx)
            }
        }
        panel.onHideSection = { [weak self] sectionID in
            guard let self else { return }
            AppSettings.shared.setPluginSetting(pluginID, "hiddenSection_\(sectionID)", true, topic: nil)
            self.cachedDetailViews.removeValue(forKey: pluginID)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginContent(id: pluginID, context: ctx)
            }
        }

        panel.setTerminalID(context.terminalID)
        restorePanelState(to: panel)

        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentTopAnchor),
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentBottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        panel.updateSections(sections, expandedIDs: expandedPluginIDs)
        pluginPanelViews[pluginID] = panel
    }

    // MARK: - Section Toggle

    private func handleSectionToggle(pluginID: String, sectionID: String) {
        if expandedPluginIDs.contains(sectionID) {
            expandedPluginIDs.remove(sectionID)
            userCollapsedSectionIDs.insert(sectionID)
        } else {
            expandedPluginIDs.insert(sectionID)
            userCollapsedSectionIDs.remove(sectionID)
        }
        savePluginStateForActiveTab()
        cachedDetailViews.removeValue(forKey: pluginID)
        if let ctx = pluginRegistry.lastContext {
            showPluginContent(id: pluginID, context: ctx)
        }
    }

    // MARK: - State Persistence

    /// Sync state from the active panel view to coordinator.
    func syncStateFromView() {
        guard let activeTabID = activePluginTabID,
            let panel = pluginPanelViews[activeTabID] as? SidebarPanelView
        else { return }

        panel.capturePersistentState()
        savedSectionHeights = panel.savedSectionHeights

        if AppSettings.shared.sidebarGlobalState {
            savedScrollOffsets = remapScrollOffsetsToGlobal(
                panel.savedScrollOffsetsSnapshot, terminalID: panel.currentTerminalID)
        } else if let terminalID = panel.currentTerminalID {
            let prefix = "\(terminalID.uuidString):"
            savedScrollOffsets = panel.savedScrollOffsetsSnapshot.filter {
                $0.key.hasPrefix(prefix)
            }
        }
    }

    /// Restore state to a panel view.
    private func restorePanelState(to panel: SidebarPanelView) {
        panel.savedSectionHeights = savedSectionHeights
        if AppSettings.shared.sidebarGlobalState {
            panel.savedScrollOffsetsSnapshot = remapGlobalScrollOffsetsToTerminal(
                savedScrollOffsets,
                terminalID: panel.currentTerminalID
            )
        } else {
            panel.savedScrollOffsetsSnapshot = savedScrollOffsets
        }
    }

    /// Save plugin state to the active tab's TabState.
    func savePluginStateForActiveTab() {
        syncStateFromView()
        guard !AppSettings.shared.sidebarGlobalState else { return }
        guard let wc = windowController,
            let ws = wc.activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID)
        else { return }

        pane.updatePluginState(
            at: pane.activeTabIndex,
            expanded: expandedPluginIDs,
            userCollapsed: userCollapsedSectionIDs,
            sidebarSectionHeights: savedSectionHeights,
            sidebarScrollOffsets: savedScrollOffsets,
            sidebarSectionOrder: savedSectionOrder,
            selectedPluginTabID: activePluginTabID
        )
    }

    // MARK: - Cleanup

    /// Remove all plugin content views.
    func removeAllContent() {
        for (_, view) in pluginPanelViews {
            view.removeFromSuperview()
        }
        pluginPanelViews.removeAll()
    }

    /// Clear cached views (forces rebuild on next cycle).
    func clearCachedViews() {
        cachedDetailViews.removeAll()
    }

    /// Clean up scroll offsets for a closed terminal.
    func cleanupScrollOffsets(for terminalID: UUID) {
        guard !AppSettings.shared.sidebarGlobalState else { return }
        let prefix = "\(terminalID.uuidString):"
        savedScrollOffsets = savedScrollOffsets.filter { !$0.key.hasPrefix(prefix) }
    }

    private func remapScrollOffsetsToGlobal(_ offsets: [String: CGPoint], terminalID: UUID?) -> [String: CGPoint] {
        guard let terminalID else { return offsets }
        let prefix = "\(terminalID.uuidString):"
        var globalOffsets: [String: CGPoint] = [:]
        for (key, value) in offsets where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            globalOffsets[Self.globalScrollOffsetPrefix + suffix] = value
        }
        return globalOffsets
    }

    private func remapGlobalScrollOffsetsToTerminal(
        _ offsets: [String: CGPoint], terminalID: UUID?
    ) -> [String: CGPoint] {
        guard let terminalID else { return [:] }
        var remapped: [String: CGPoint] = [:]
        for (key, value) in offsets where key.hasPrefix(Self.globalScrollOffsetPrefix) {
            let suffix = String(key.dropFirst(Self.globalScrollOffsetPrefix.count))
            remapped["\(terminalID.uuidString):\(suffix)"] = value
        }
        return remapped
    }

    // MARK: - Utilities

    /// Remap scroll offsets from one terminal to another.
    func remapScrollOffsets(
        _ offsets: [String: CGPoint],
        from sourceID: UUID,
        to targetID: UUID
    ) -> [String: CGPoint] {
        let sourcePrefix = "\(sourceID.uuidString):"
        let targetPrefix = "\(targetID.uuidString):"

        var remapped: [String: CGPoint] = [:]
        for (key, value) in offsets where key.hasPrefix(sourcePrefix) {
            let suffix = String(key.dropFirst(sourcePrefix.count))
            remapped[targetPrefix + suffix] = value
        }
        return remapped
    }

    /// Update theme colors on the sidebar container.
    func updateTheme(_ theme: TerminalTheme) {
        sidebarContainer?.layer?.backgroundColor = theme.sidebarBg.cgColor
    }
}
