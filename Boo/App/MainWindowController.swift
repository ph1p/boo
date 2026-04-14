import CGhostty
import Cocoa
import Combine
import SwiftUI

// SidebarScrollPanelView is added directly to sidebarContainer (no SwiftUI bridge).

/// NSSplitView with themed divider color and a VS Code-style accent hover highlight.
class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        AppSettings.shared.theme.sidebarBorder
    }

    private var dividerHoverHighlighted = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard subviews.count >= 2 else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let divX = subviews[0].frame.maxX
        let highlighted = abs(localPoint.x - divX) <= 4
        if highlighted != dividerHoverHighlighted {
            dividerHoverHighlighted = highlighted
            // Invalidate only the divider strip, not the whole split view
            let dividerStrip = CGRect(x: divX - 4, y: 0, width: 9, height: bounds.height)
            setNeedsDisplay(dividerStrip)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if dividerHoverHighlighted {
            dividerHoverHighlighted = false
            if subviews.count >= 2 {
                let divX = subviews[0].frame.maxX
                setNeedsDisplay(CGRect(x: divX - 4, y: 0, width: 9, height: bounds.height))
            }
        }
    }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)
        guard dividerHoverHighlighted else { return }
        let barW: CGFloat = 2
        let bar = CGRect(x: rect.midX - barW / 2, y: rect.minY, width: barW, height: rect.height)
        AppSettings.shared.theme.accentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: bar).fill()
    }
}

class MainWindowController: NSWindowController, SplitContainerDelegate, NSSplitViewDelegate {
    let appState = AppState()

    let toolbar = ToolbarView(frame: .zero)
    let statusBar = StatusBarView(frame: .zero)
    var statusBarHeightConstraint: NSLayoutConstraint?
    var splitContainer: SplitContainerView!
    var mainSplitView: NSSplitView!

    // MARK: - Sidebar Controller

    /// Dedicated controller for sidebar panel management.
    /// Handles plugin tabs, section heights, scroll offsets, and visibility.
    var sidebarController: SidebarController!

    var sidebarContainer: NSView! {
        get { sidebarController?.sidebarContainer }
        set { sidebarController?.sidebarContainer = newValue }
    }

    var sidebarVisible: Bool {
        get { sidebarController?.isVisible ?? !AppSettings.shared.sidebarDefaultHidden }
        set { sidebarController?.isVisible = newValue }
    }

    var sidebarUserHidden: Bool {
        get { sidebarController?.isUserHidden ?? AppSettings.shared.sidebarDefaultHidden }
        set { sidebarController?.isUserHidden = newValue }
    }
    var isRemoteSidebar: Bool { coordinator?.isRemote ?? false }
    var currentSidebarPosition: SidebarPosition {
        get { sidebarController?.position ?? .right }
        set { sidebarController?.position = newValue }
    }
    var currentWorkspaceBarPosition: WorkspaceBarPosition = .left
    var currentTabOverflowMode: TabOverflowMode = .scroll
    var sideWorkspaceBar: WorkspaceBarView?
    var sideWorkspaceBarWidthConstraint: NSLayoutConstraint?
    var mainSplitLeadingConstraint: NSLayoutConstraint?
    var toolbarLeadingConstraint: NSLayoutConstraint?
    var mainSplitTrailingConstraint: NSLayoutConstraint?
    var toolbarTrailingConstraint: NSLayoutConstraint?

    /// PaneViews keyed by workspace ID → pane ID → PaneView
    var workspacePaneViews: [UUID: [UUID: PaneView]] = [:]

    /// Convenience accessor for current workspace's pane views
    var paneViews: [UUID: PaneView] {
        get { workspacePaneViews[activeWorkspace?.id ?? UUID()] ?? [:] }
        set { if let id = activeWorkspace?.id { workspacePaneViews[id] = newValue } }
    }
    private var settingsObserver: Any?
    private var ghosttyActionObserver: Any?
    var coordinator: WindowStateCoordinator!
    var bridge: TerminalBridge! { coordinator.bridge }
    var bridgeCancellables = Set<AnyCancellable>()
    private let contextAnnouncer = ContextAnnouncementEngine()

    /// Coalesced plugin cycle scheduling — batches rapid-fire events within one run loop tick.
    private var pendingCycleReason: PluginCycleReason?
    private var cycleScheduled = false

    /// Pending image sends keyed by tab ID, waiting for a live shell PID.
    /// `failedPID` is the PID that last failed — only retry with a different PID.
    var pendingImageSends: [UUID: (path: String, size: ghostty_surface_size_s?, failedPID: pid_t)] = [:]

    /// Registry of factories for named custom tab types (registerMultiContentTab API).
    var multiContentTabFactories: [String: (PluginTabContext) -> AnyView] = [:]
    /// Maps tabID → "typeID:key" for deduplication in openMultiContentTab.
    var registeredTabKeys: [UUID: String] = [:]

    /// Focus debounce — prevents sidebar rebuild from causing a focus feedback loop.
    var lastFocusedPaneID: UUID?
    /// Debounce timer for saving the session after split-pane divider drags.
    private var splitRatioSaveTimer: Timer?
    var lastFocusTimestamp: UInt64 = 0
    /// Last pane ID for which plugins received a focusChanged notification.
    /// Prevents redundant notifications when the same pane re-focuses.
    var lastFocusedPluginPaneID: UUID?
    var pluginRegistry: PluginRegistry { coordinator.pluginRegistry }
    /// Persisted sidebar section heights — tracked per terminal/tab.
    var savedSidebarHeights: [String: CGFloat] {
        get { coordinator?.sidebarSectionHeights ?? [:] }
        set { coordinator?.sidebarSectionHeights = newValue }
    }
    /// Persisted sidebar scroll offsets — tracked per terminal/tab.
    var savedSidebarScrollOffsets: [String: CGPoint] {
        get { coordinator?.sidebarScrollOffsets ?? [:] }
        set { coordinator?.sidebarScrollOffsets = newValue }
    }
    /// Persisted sidebar section order per plugin — tracked per terminal/tab.
    var savedSidebarSectionOrder: [String: [String]] {
        get { coordinator?.sidebarSectionOrder ?? [:] }
        set { coordinator?.sidebarSectionOrder = newValue }
    }
    var cachedDetailViews: [String: (context: TerminalContext, generations: [UInt64], view: AnyView)] {
        get { sidebarController?.cachedDetailViews ?? [:] }
        set { sidebarController?.cachedDetailViews = newValue }
    }
    var pluginViewGeneration: [String: UInt64] {
        get { sidebarController?.pluginViewGeneration ?? [:] }
        set { sidebarController?.pluginViewGeneration = newValue }
    }
    var viewGenerationCounter: UInt64 {
        get { sidebarController?.viewGenerationCounter ?? 0 }
        set { sidebarController?.viewGenerationCounter = newValue }
    }
    /// Set of plugin IDs currently expanded (not collapsed) in the sidebar.
    var expandedPluginIDs: Set<String> {
        get { coordinator.expandedPluginIDs }
        set { coordinator.expandedPluginIDs = newValue }
    }
    var userCollapsedSectionIDs: Set<String> {
        get { coordinator.userCollapsedSectionIDs }
        set { coordinator.userCollapsedSectionIDs = newValue }
    }
    /// Track the previous tab for saving state on switch.
    var previousFocusedTabID: UUID? {
        get { coordinator.previousFocusedTabID }
        set { coordinator.previousFocusedTabID = newValue }
    }
    var pluginPanelViews: [String: NSView] {
        get { sidebarController?.pluginPanelViews ?? [:] }
        set { sidebarController?.pluginPanelViews = newValue }
    }
    var activePluginTabID: String? {
        get { sidebarController?.activePluginTabID }
        set { sidebarController?.activePluginTabID = newValue }
    }
    var sidebarTabBarView: SidebarTabBarView? {
        get { sidebarController?.sidebarTabBarView }
        set { sidebarController?.sidebarTabBarView = newValue }
    }
    var sidebarTabBarPositionConstraints: [NSLayoutConstraint] {
        get { sidebarController?.sidebarTabBarPositionConstraints ?? [] }
        set { sidebarController?.sidebarTabBarPositionConstraints = newValue }
    }

    let tabDragCoordinator = TabDragCoordinator()

    deinit {
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = ghosttyActionObserver { NotificationCenter.default.removeObserver(obs) }
        bridgeCancellables.removeAll()
    }

    /// Undo stack for closed tabs and panes
    enum ClosedItem {
        case tab(paneID: UUID, workingDirectory: String, index: Int)
        case pane(siblingPaneID: UUID, workingDirectory: String, direction: SplitTree.SplitDirection)
    }
    var undoStack: [ClosedItem] = []

    /// Keep closed sessions alive briefly so undo can restore them
    private var sessionCacheTimer: Timer?

    var activeRemoteSession: RemoteSessionType? {
        coordinator?.activeRemoteSession
    }

    var pluginWatcher: PluginWatcher?

    func notifyTerminalClosed(for terminalID: UUID) {
        pluginRegistry.notifyTerminalClosed(terminalID: terminalID)
        pendingImageSends.removeValue(forKey: terminalID)
        // Clean up stale scroll offsets for the closed terminal.
        // Coordinator is authoritative; panel copy is cleaned to stay in sync.
        let prefix = "\(terminalID.uuidString):"
        coordinator?.sidebarScrollOffsets = coordinator?.sidebarScrollOffsets.filter {
            !$0.key.hasPrefix(prefix)
        } ?? [:]
        if let panel = activePluginTabID.flatMap({ pluginPanelViews[$0] as? SidebarPanelView }) {
            panel.cleanupScrollOffsets(for: terminalID)
        }
    }

    func notifyTerminalClosed(for tabs: [Pane.Tab]) {
        for tab in tabs {
            notifyTerminalClosed(for: tab.id)
        }
    }

    var activeWorkspace: Workspace? { appState.activeWorkspace }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Boo"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("BooMainWindow")
        window.backgroundColor = AppSettings.shared.theme.chromeBg
        window.appearance = NSAppearance(named: AppSettings.shared.theme.isDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = false

        super.init(window: window)

        // Initialize coordinator and sidebar controller before UI setup
        let theBridge = TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "")
        let theRegistry = PluginRegistry()
        coordinator = WindowStateCoordinator(bridge: theBridge, pluginRegistry: theRegistry)
        sidebarController = SidebarController(windowController: self)

        setupUI()
        statusBar.sidebarVisible = sidebarVisible
        AppStore.shared.sidebarVisible = sidebarVisible
        setupMenuItems()
        pluginRegistry.onRequestCycleRerun = { [weak self] in
            guard let self = self else { return }
            // A plugin's internal state changed — clear view cache and force sidebar rebuild.
            self.cachedDetailViews.removeAll()
            self.pluginRegistry.clearChangeDetection()
            self.runPluginCycle(reason: .focusChanged)
        }
        pluginRegistry.registerBuiltins()
        // Keep status bar branch cache in sync with GitPlugin's .git/HEAD watcher.
        // This ensures the branch updates immediately after git switch/checkout without
        // waiting for a CWD change event.
        if let gitPlugin = pluginRegistry.plugin(for: "git-panel") as? GitPlugin {
            gitPlugin.onBranchChanged = { [weak self] branch, repoRoot in
                guard let self else { return }
                let cwd = self.statusBar.currentDirectory
                booLog(.debug, .git, "onBranchChanged: branch=\(branch ?? "nil") repoRoot=\(repoRoot ?? "nil") statusBar.cwd=\(cwd)")
                // Only update the status bar branch if the focused terminal is inside this repo.
                // Ignore watcher events from other terminals' repos.
                guard let root = repoRoot,
                    cwd == root || cwd.hasPrefix(root + "/")
                else {
                    booLog(.debug, .git, "onBranchChanged: ignored (cwd not in repo)")
                    return
                }
                self.statusBar.gitBranch = branch
                self.statusBar.gitRepoRoot = repoRoot
                self.statusBar.needsDisplay = true
            }
        }
        let pluginActions = PluginActions()
        pluginActions.sendToTerminal = { [weak self] in self?.sendRawToActivePane($0) }
        pluginActions.openDirectoryInNewTab = { [weak self] in self?.openDirectoryInNewTab($0) }
        pluginActions.openDirectoryInNewPane = { [weak self] in self?.openDirectoryInNewPane($0) }
        pluginActions.openFileInNewPane = { [weak self] in self?.openFileInNewPane($0) }
        pluginActions.pastePathToActivePane = { [weak self] in self?.pastePathToActivePane($0) }
        pluginActions.isTerminalBusy = { [weak self] in
            guard let self else { return false }
            let process = self.bridge.state.foregroundProcess
            return !process.isEmpty && !ProcessIcon.isShell(process)
        }
        pluginActions.openTab = { [weak self] payload in
            self?.handleOpenTab(payload)
        }
        pluginActions.setAgentSessionID = { [weak self] sessionID in
            guard let self,
                let workspace = self.activeWorkspace,
                let pane = workspace.pane(for: workspace.activePaneID)
            else { return }
            pane.updateAgentSessionID(sessionID)
        }
        pluginActions.getAgentSessionID = { [weak self] in
            guard let self,
                let workspace = self.activeWorkspace,
                let pane = workspace.pane(for: workspace.activePaneID)
            else { return nil }
            return pane.activeTab?.state.agentSessionID
        }
        pluginActions.displayImageInTerminal = { [weak self] path, newTab in
            guard let self, let workspace = self.activeWorkspace else { return }
            let paneID = workspace.activePaneID
            let activeTabID = workspace.pane(for: paneID)?.activeTab?.id
            let size: ghostty_surface_size_s? = self.ghosttyView(for: paneID)?.surface.map {
                ghostty_surface_size($0)
            }
            func send(tabID: UUID, to shellPID: pid_t) {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let ok = KittyImageProtocol.sendImage(imagePath: path, to: shellPID, terminalSize: size)
                    if !ok {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.pendingImageSends[tabID] = (path, size, shellPID)
                            // zsh may have re-exec'd — refresh from the login process.
                            self.ghosttyView(for: paneID)?.refreshShellPIDIfNeeded(currentPID: shellPID)
                        }
                    }
                }
            }
            if newTab {
                guard let pv = self.paneViews[paneID],
                    let newTabID = pv.addNewTab(workingDirectory: path.deletingLastPathComponent)
                else { return }
                self.refreshStatusBar()
                // Queue keyed by the new tab's ID — isolated from other tabs' retries.
                self.pendingImageSends[newTabID] = (path, size, 0)
            } else {
                guard let tabID = activeTabID else { return }
                guard let shellPID = self.bridge.monitor.shellPID(for: paneID) else {
                    self.pendingImageSends[tabID] = (path, size, 0)
                    return
                }
                send(tabID: tabID, to: shellPID)
            }
        }
        pluginActions.registerMultiContentTab = { [weak self] typeID, factory in
            self?.multiContentTabFactories[typeID] = factory
        }
        pluginActions.openMultiContentTab = { [weak self] typeID, ctx in
            self?.handleOpenMultiContentTab(typeID: typeID, context: ctx)
        }
        pluginRegistry.actions = pluginActions
        bridge.monitor.onShellPIDUpdated = { [weak self] paneID, shellPID, tabID in
            guard let self, let tabID else { return }
            let isNewTab = self.pendingImageSends[tabID]?.failedPID == 0
            if isNewTab {
                // Delay sending until zsh has finished init and printed its first prompt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.flushPendingImageSend(for: tabID, shellPID: shellPID)
                }
            } else {
                self.flushPendingImageSend(for: tabID, shellPID: shellPID)
            }
        }
        pluginRegistry.hostActions = PluginHostActions(
            pastePathToActivePane: { [weak self] in self?.pastePathToActivePane($0) },
            openDirectoryInNewTab: { [weak self] in self?.openDirectoryInNewTab($0) },
            openDirectoryInNewPane: { [weak self] in self?.openDirectoryInNewPane($0) },
            sendRawToActivePane: { [weak self] in self?.sendRawToActivePane($0) }
        )
        tabDragCoordinator.onDrop = { [weak self] source, tabIndex, dest, zone in
            self?.handleTabDrop(source: source, tabIndex: tabIndex, dest: dest, zone: zone)
        }
        tabDragCoordinator.onWorkspaceHover = { [weak self] index in
            guard let self = self, index != self.appState.activeWorkspaceIndex else { return }
            self.activateWorkspace(index)
        }
        tabDragCoordinator.workspacePillFrames = { [weak self] in
            self?.workspacePillScreenFrames() ?? []
        }
        restoreWorkspaces()
        subscribeToBridge()
        setupIPCHandlers()
        setupPluginWatcher()

        // Run initial plugin cycle so lastContext is available for first click
        DispatchQueue.main.async { [weak self] in
            self?.runPluginCycle(reason: .focusChanged)
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self, self.window?.isVisible == true else { return }
            let topic = (notification.userInfo?["topic"] as? String).flatMap(SettingsTopic.init(rawValue:))

            // Broadcast settings/theme changes to socket subscribers
            if let t = topic {
                BooSocketServer.shared.emitSettingsChanged(topic: t.rawValue)
            }

            // Theme changes: refresh chrome colors, pane backgrounds, sidebar, status bar
            if topic == nil || topic == .theme {
                MainActor.assumeIsolated { AppStore.shared.refreshTheme() }
                let theme = AppSettings.shared.theme
                BooSocketServer.shared.emitThemeChanged(name: theme.name, isDark: theme.isDark)
                self.window?.backgroundColor = theme.chromeBg
                self.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                self.sidebarContainer.layer?.backgroundColor = theme.sidebarBg.cgColor
                self.splitContainer.layer?.backgroundColor = theme.background.nsColor.cgColor
                self.mainSplitView.needsDisplay = true
                self.toolbar.needsDisplay = true
                self.statusBar.needsDisplay = true
                for (_, pv) in self.paneViews {
                    pv.layer?.backgroundColor = theme.background.nsColor.cgColor
                    pv.needsLayout = true
                    pv.needsDisplay = true
                }
                // Rebuild plugin sidebar to pick up new theme
                if let ctx = MainActor.assumeIsolated({ self.pluginRegistry.lastContext }) {
                    self.cachedDetailViews.removeAll()
                    self.rebuildSidebarTabs(context: ctx)
                }
            }

            // Status bar changes
            if topic == nil || topic == .statusBar {
                self.statusBar.needsDisplay = true
            }

            // Layout changes: sidebar/workspace bar position, density
            if topic == nil || topic == .layout {
                self.statusBarHeightConstraint?.constant = DensityMetrics.current.statusBarHeight
                self.statusBar.needsDisplay = true
                let newSidebarPos = AppSettings.shared.sidebarPosition
                if newSidebarPos != self.currentSidebarPosition {
                    self.currentSidebarPosition = newSidebarPos
                    self.rebuildSidebarLayout()
                }
                let newWsBarPos = AppSettings.shared.workspaceBarPosition
                if newWsBarPos != self.currentWorkspaceBarPosition {
                    self.currentWorkspaceBarPosition = newWsBarPos
                    self.rebuildWorkspaceBarLayout()
                }
                let newTabOverflow = AppSettings.shared.tabOverflowMode
                if newTabOverflow != self.currentTabOverflowMode {
                    self.currentTabOverflowMode = newTabOverflow
                    for (_, pv) in self.paneViews {
                        pv.needsLayout = true
                        pv.needsDisplay = true
                    }
                }
                // Tab bar position changed — swap constraints and re-install content views
                self.applySidebarTabBarPositionConstraints()
                if let ctx = MainActor.assumeIsolated({ self.pluginRegistry.lastContext }) {
                    self.cachedDetailViews.removeAll()
                    self.removeAllPluginContent()
                    self.rebuildSidebarTabs(context: ctx)
                }
            }

            // Plugin changes: deactivate any now-disabled plugins and run a fresh cycle.
            if topic == .plugins {
                let disabled = AppSettings.shared.disabledPluginIDsSet
                // Deactivate plugins that just got disabled
                MainActor.assumeIsolated {
                    for plugin in self.pluginRegistry.plugins where disabled.contains(plugin.pluginID) {
                        self.pluginRegistry.deactivatePlugin(plugin.pluginID)
                        self.cachedDetailViews.removeValue(forKey: plugin.pluginID)
                    }
                    self.pluginRegistry.clearChangeDetection()
                }
            }

            // Explorer/plugin/font changes: refresh sidebar
            if topic == nil || topic == .explorer || topic == .sidebarFont || topic == .plugins {
                if topic == .sidebarFont, let ctx = MainActor.assumeIsolated({ self.pluginRegistry.lastContext }) {
                    if self.sidebarVisible {
                        self.cachedDetailViews.removeAll()
                        self.rebuildSidebarTabs(context: ctx)
                    }
                } else {
                    self.runPluginCycle(reason: .focusChanged)
                }
            }
        }

        ghosttyActionObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyAction, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let info = notification.userInfo,
                let action = info["action"] as? String
            else { return }
            self.handleGhosttyAction(action, userInfo: info)
        }

        NotificationCenter.default.addObserver(
            forName: .ghosttyOpenURL, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let url = notification.userInfo?["url"] as? URL
            else { return }
            self.handleOpenTab(.browser(url: url))
        }
    }

    private func handleGhosttyAction(_ action: String, userInfo: [AnyHashable: Any]) {
        switch action {
        case "new_split":
            let dirStr = userInfo["direction"] as? String ?? "vertical"
            if dirStr == "horizontal" {
                splitHorizontalAction(nil)
            } else {
                splitVerticalAction(nil)
            }

        case "goto_split":
            let dir = userInfo["direction"] as? String ?? "next"
            if dir == "next" {
                focusNextPaneAction(nil)
            } else {
                focusPrevPaneAction(nil)
            }

        case "equalize_splits":
            guard let workspace = activeWorkspace else { return }
            workspace.equalizeSplits()
            splitContainer.update(tree: workspace.splitTree)

        case "close_surface":
            smartCloseAction(nil)

        case "new_tab":
            newTabAction(nil)

        case "new_workspace":
            newWorkspaceAction(nil)

        case "toggle_fullscreen":
            window?.toggleFullScreen(nil)

        case "close_window":
            window?.close()

        case "open_settings":
            showSettingsAction(nil)

        default:
            break
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.delegate = self
        contentView.addSubview(toolbar)

        mainSplitView = ThemedSplitView()
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.delegate = self
        contentView.addSubview(mainSplitView)

        splitContainer = SplitContainerView(frame: .zero)
        splitContainer.splitDelegate = self
        splitContainer.onRatioChanged = { [weak self] updatedTree in
            guard let self, let ws = self.activeWorkspace else { return }
            ws.splitTree = updatedTree
            self.splitRatioSaveTimer?.invalidate()
            self.splitRatioSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.saveSession()
            }
        }

        sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor

        // Sidebar tab bar
        let tabBar = SidebarTabBarView(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] tab in
            guard let self, let ctx = self.pluginRegistry.lastContext else { return }
            self.activatePluginTab(tab, context: ctx)
        }
        tabBar.onTabDisabled = { tab in
            var disabled = AppSettings.shared.disabledPluginIDs
            if !disabled.contains(tab.id) {
                disabled.append(tab.id)
                AppSettings.shared.disabledPluginIDs = disabled
            }
        }
        tabBar.onToggleSection = { [weak self] tabID, sectionID in
            guard let self else { return }
            let key = "hiddenSection_\(sectionID)"
            let isCurrentlyHidden = AppSettings.shared.pluginBool(tabID.id, key, default: false)
            AppSettings.shared.setPluginSetting(tabID.id, key, !isCurrentlyHidden, topic: nil)
            self.cachedDetailViews.removeValue(forKey: tabID.id)
            if let ctx = self.pluginRegistry.lastContext {
                self.showPluginTabContent(id: tabID.id, context: ctx)
            }
        }
        tabBar.onTabsReordered = { tabs in
            let visibleIDs = tabs.map(\.id)
            AppSettings.shared.sidebarTabOrder = SidebarTabOrdering.mergeOrder(
                saved: AppSettings.shared.sidebarTabOrder,
                visible: visibleIDs)
        }
        sidebarContainer.addSubview(tabBar)
        sidebarTabBarView = tabBar
        let fixedConstraints = [
            tabBar.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: SidebarTabBarView.height)
        ]
        NSLayoutConstraint.activate(fixedConstraints)
        applySidebarTabBarPositionConstraints()

        currentSidebarPosition = AppSettings.shared.sidebarPosition
        if sidebarVisible {
            if currentSidebarPosition == .left {
                mainSplitView.addSubview(sidebarContainer)
                mainSplitView.addSubview(splitContainer)
            } else {
                mainSplitView.addSubview(splitContainer)
                mainSplitView.addSubview(sidebarContainer)
            }
        } else {
            mainSplitView.addSubview(splitContainer)
        }

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.onBranchSwitch = { [weak self] branch in
            let escaped = RemoteExplorer.shellEscPath(branch)
            self?.sendRawToActivePane("git switch \(escaped)\r")
        }
        statusBar.onSidebarToggle = { [weak self] in
            self?.toggleSidebar(userInitiated: true)
        }
        statusBar.onPluginSegmentClick = { [weak self] pluginID in
            guard let self, let ctx = self.pluginRegistry.lastContext else { return }
            self.activatePluginTab(SidebarTabID(pluginID), context: ctx)
        }
        contentView.addSubview(statusBar)

        currentWorkspaceBarPosition = AppSettings.shared.workspaceBarPosition
        currentTabOverflowMode = AppSettings.shared.tabOverflowMode

        // Create leading/trailing constraints that can be adjusted for side workspace bar
        let toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let toolbarTrailing = toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        let mainSplitLeading = mainSplitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let mainSplitTrailing = mainSplitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        toolbarLeadingConstraint = toolbarLeading
        toolbarTrailingConstraint = toolbarTrailing
        mainSplitLeadingConstraint = mainSplitLeading
        mainSplitTrailingConstraint = mainSplitTrailing

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarLeading,
            toolbarTrailing,
            toolbar.heightAnchor.constraint(equalToConstant: 38),

            mainSplitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            mainSplitLeading,
            mainSplitTrailing,
            mainSplitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        if currentWorkspaceBarPosition == .left || currentWorkspaceBarPosition == .right {
            setupSideWorkspaceBar(in: contentView, position: currentWorkspaceBarPosition)
        }
        let heightConstraint = statusBar.heightAnchor.constraint(
            equalToConstant: DensityMetrics.current.statusBarHeight)
        heightConstraint.isActive = true
        statusBarHeightConstraint = heightConstraint

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sidebarW = AppSettings.shared.sidebarWidth
            let pos: CGFloat
            if self.currentSidebarPosition == .left {
                pos = sidebarW
            } else {
                pos = self.mainSplitView.bounds.width - sidebarW
            }
            if self.currentSidebarPosition == .left {
                if pos < self.mainSplitView.bounds.width - 300 {
                    self.mainSplitView.setPosition(pos, ofDividerAt: 0)
                }
            } else {
                if pos > 300 { self.mainSplitView.setPosition(pos, ofDividerAt: 0) }
            }
        }
    }

    /// Setup a vertical workspace bar on the given edge.
    private func setupSideWorkspaceBar(in contentView: NSView, position: WorkspaceBarPosition) {
        let bar = WorkspaceBarView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isVertical = true
        bar.isRightAligned = position == .right
        bar.delegate = self
        contentView.addSubview(bar)

        let widthConstraint = bar.widthAnchor.constraint(equalToConstant: 40)
        sideWorkspaceBarWidthConstraint = widthConstraint

        var constraints = [
            bar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            widthConstraint
        ]

        if position == .left {
            constraints.append(bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor))
            toolbarLeadingConstraint?.constant = 40
            mainSplitLeadingConstraint?.constant = 40
        } else {
            constraints.append(bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor))
            toolbarTrailingConstraint?.constant = -40
            mainSplitTrailingConstraint?.constant = -40
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
        toolbarLeadingConstraint?.constant = 0
        mainSplitLeadingConstraint?.constant = 0
        toolbarTrailingConstraint?.constant = 0
        mainSplitTrailingConstraint?.constant = 0
        toolbar.hideWorkspaces = false
        toolbar.needsDisplay = true
    }

    /// Rebuild workspace bar position (called on settings change).
    private func rebuildWorkspaceBarLayout() {
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

    /// Rebuild the sidebar position within the main split view.
    /// Apply (or re-apply) the positional constraints for the sidebar tab bar based on
    /// `AppSettings.shared.sidebarTabBarPosition`. Deactivates any previously active constraints.
    func applySidebarTabBarPositionConstraints() {
        guard let tabBar = sidebarTabBarView else { return }
        NSLayoutConstraint.deactivate(sidebarTabBarPositionConstraints)
        if AppSettings.shared.sidebarTabBarPosition == .bottom {
            sidebarTabBarPositionConstraints = [
                tabBar.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor)
            ]
        } else {
            sidebarTabBarPositionConstraints = [
                tabBar.topAnchor.constraint(equalTo: sidebarContainer.topAnchor)
            ]
        }
        NSLayoutConstraint.activate(sidebarTabBarPositionConstraints)
    }

    private func rebuildSidebarLayout() {
        let wasSidebarVisible = sidebarVisible
        // Remove both subviews
        splitContainer.removeFromSuperview()
        sidebarContainer.removeFromSuperview()

        // Re-add in correct order
        if currentSidebarPosition == .left {
            mainSplitView.addSubview(sidebarContainer)
            mainSplitView.addSubview(splitContainer)
        } else {
            mainSplitView.addSubview(splitContainer)
            mainSplitView.addSubview(sidebarContainer)
        }

        if !wasSidebarVisible {
            sidebarContainer.removeFromSuperview()
        } else {
            mainSplitView.adjustSubviews()
            let sidebarW = AppSettings.shared.sidebarWidth
            let pos: CGFloat = currentSidebarPosition == .left ? sidebarW : mainSplitView.bounds.width - sidebarW
            mainSplitView.setPosition(pos, ofDividerAt: 0)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView {
            return currentSidebarPosition == .left ? 140 : 300
        }
        return p
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView {
            return currentSidebarPosition == .left ? splitView.bounds.width - 300 : splitView.bounds.width - 140
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

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard sidebarVisible else { return }
        let sidebarIdx = currentSidebarPosition == .left ? 0 : 1
        guard sidebarIdx < mainSplitView.subviews.count else { return }
        let width = mainSplitView.subviews[sidebarIdx].frame.width
        if abs(width - AppSettings.shared.sidebarWidth) > 2 {
            AppSettings.shared.sidebarWidth = width
        }
    }

    // MARK: - Terminal Bridge

    /// Schedule a plugin cycle, coalescing multiple events within the same run loop tick.
    /// The highest-priority reason wins when multiple events arrive before the cycle runs.
    func schedulePluginCycle(reason: PluginCycleReason) {
        if let existing = pendingCycleReason {
            pendingCycleReason = Self.higherPriority(existing, reason)
        } else {
            pendingCycleReason = reason
        }
        guard !cycleScheduled else { return }
        cycleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let reason = self.pendingCycleReason else { return }
            self.pendingCycleReason = nil
            self.cycleScheduled = false
            self.runPluginCycle(reason: reason)
        }
    }

    private static func higherPriority(_ a: PluginCycleReason, _ b: PluginCycleReason) -> PluginCycleReason {
        func rank(_ r: PluginCycleReason) -> Int {
            switch r {
            case .titleChanged: return 0
            case .processChanged: return 1

            case .focusChanged: return 2
            case .cwdChanged: return 3
            case .remoteSessionChanged: return 4
            case .workspaceSwitched: return 5
            }
        }
        return rank(b) >= rank(a) ? b : a
    }

    private func subscribeToBridge() {
        bridgeCancellables.removeAll()
        contextAnnouncer.subscribe(to: bridge)

        bridge.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self = self else { return }
                // Sync bridge state to the active tab immediately so tab bar
                // and all UI reads from tab state are always fresh.
                if let ws = self.activeWorkspace,
                    let pane = ws.pane(for: state.paneID)
                {
                    self.coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
                    self.paneViews[pane.id]?.needsDisplay = true
                }
                // Refresh the status bar from AppStore.shared.context.
                // A full plugin cycle is NOT needed here — bridge.events already
                // schedules one with the correct reason for each event type.
                self.refreshStatusBar()
            }
            .store(in: &bridgeCancellables)

        // When a process registers/unregisters via the socket, re-evaluate.
        BooSocketServer.shared.onStatusChanged = { [weak self] in
            guard let self else { return }
            self.bridge.reevaluateSocketProcess()
        }

        bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self = self else { return }
                let socket = BooSocketServer.shared
                switch event {
                case .directoryChanged(let path):
                    socket.emitCwdChanged(
                        path: path, isRemote: self.bridge.state.remoteSession != nil, paneID: self.bridge.state.paneID)
                    self.schedulePluginCycle(reason: .cwdChanged)

                case .titleChanged(let title):
                    socket.emitTitleChanged(title: title, paneID: self.bridge.state.paneID)
                    self.schedulePluginCycle(reason: .titleChanged)

                case .processChanged(let name):
                    socket.emitProcessChanged(
                        name: name, category: ProcessIcon.category(for: name), paneID: self.bridge.state.paneID)
                    self.schedulePluginCycle(reason: .processChanged)

                case .remoteSessionChanged(let session):
                    socket.emitRemoteSessionChanged(session: session, paneID: self.bridge.state.paneID)
                    self.syncRemoteSidebarState()
                    self.schedulePluginCycle(reason: .remoteSessionChanged)

                case .focusChanged(let paneID):
                    socket.emitFocusChanged(paneID: paneID)
                    // Only refresh toolbar — didFocus already runs a synchronous plugin cycle.
                    // Scheduling another async cycle causes sidebar rebuild → GhosttyView focus
                    // callback → didFocus → infinite loop.
                    self.refreshToolbar()

                case .workspaceSwitched(let workspaceID):
                    socket.emitWorkspaceSwitched(workspaceID: workspaceID)
                    self.refreshToolbar()
                    self.schedulePluginCycle(reason: .workspaceSwitched)

                case .remoteDirectoryListed(let path, let entries):
                    self.pluginRegistry.notifyRemoteDirectoryListed(path: path, entries: entries)
                    self.schedulePluginCycle(reason: .cwdChanged)

                case .commandStarted, .commandEnded:
                    // Emitted via paneView delegate before bridge events fire; no further action needed.
                    break

                }
            }
            .store(in: &bridgeCancellables)
    }

    func syncRemoteSidebarState() {
        // isRemoteSidebar and activeRemoteSession are now derived from bridge state.
        // Just trigger a plugin cycle if remote state is relevant.
        let session = bridge.state.remoteSession
        schedulePluginCycle(reason: session != nil ? .remoteSessionChanged : .cwdChanged)
    }

    // MARK: - SplitContainerDelegate

    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView {
        if let existing = paneViews[paneID] {
            return existing
        }

        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: paneID)
        else {
            return PaneView(paneID: paneID, pane: Pane(id: paneID))
        }

        let pv = PaneView(paneID: paneID, pane: pane)
        pv.paneDelegate = self
        pv.tabDragCoordinator = tabDragCoordinator
        paneViews[paneID] = pv
        return pv
    }

    // MARK: - Actions

    @objc func newWorkspaceAction(_ sender: Any?) {
        openWorkspace(path: AppSettings.shared.defaultFolder)
    }

    @objc func openFolderAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open as a workspace"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openWorkspace(path: url.path)
        }
    }

    @objc func newTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let cwd: String
        if AppSettings.shared.newTabCwdMode == .samePath,
            let activeCwd = workspace.pane(for: workspace.activePaneID)?.activeTab?.workingDirectory
        {
            cwd = activeCwd
        } else {
            cwd = workspace.folderPath
        }
        pv.addNewTab(workingDirectory: cwd)
        saveSession()
    }

    @objc func newBrowserTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        pv.addNewTab(contentType: .browser, url: ContentType.newTabURL)
        saveSession()
    }

    /// Open a new tab of the specified content type (used by context menus).
    @objc func newTabOfType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType,
            let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let cwd: String
        if AppSettings.shared.newTabCwdMode == .samePath,
            let activeCwd = workspace.pane(for: workspace.activePaneID)?.activeTab?.workingDirectory
        {
            cwd = activeCwd
        } else {
            cwd = workspace.folderPath
        }
        pv.addNewTab(contentType: type, workingDirectory: cwd)
        saveSession()
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        toggleSidebar(userInitiated: sender != nil)
    }

    /// Toggle sidebar visibility. When `userInitiated` is true, the flag is
    /// recorded so the plugin system won't auto-show the sidebar on tab switch.
    func toggleSidebar(userInitiated: Bool) {
        // Don't allow showing the sidebar when no tabs are available
        if !sidebarVisible && sidebarTabBarView?.sidebarTabs.isEmpty == true {
            return
        }
        sidebarVisible.toggle()
        if userInitiated {
            sidebarUserHidden = !sidebarVisible
        }
        if sidebarVisible {
            if currentSidebarPosition == .left {
                // Insert sidebar before split container
                mainSplitView.subviews.insert(sidebarContainer, at: 0)
            } else {
                mainSplitView.addSubview(sidebarContainer)
            }
            mainSplitView.adjustSubviews()
            let sidebarW = AppSettings.shared.sidebarWidth
            let pos: CGFloat = currentSidebarPosition == .left ? sidebarW : mainSplitView.bounds.width - sidebarW
            mainSplitView.setPosition(pos, ofDividerAt: 0)
        } else {
            sidebarContainer.removeFromSuperview()
        }
        for (_, pv) in paneViews {
            pv.currentTerminalView?.needsDisplay = true
            pv.currentTerminalView?.needsLayout = true
        }
        statusBar.sidebarVisible = sidebarVisible
        AppStore.shared.sidebarVisible = sidebarVisible
        statusBar.needsDisplay = true
        refreshToolbar()
    }

    @objc func splitVerticalAction(_ sender: Any?) {
        splitActivePane(direction: .horizontal)
    }

    @objc func splitHorizontalAction(_ sender: Any?) {
        splitActivePane(direction: .vertical)
    }

    @objc func showSettingsAction(_ sender: Any?) {
        PluginSettingsView.registeredManifests = pluginRegistry.plugins.map(\.manifest)
        SettingsWindowController.shared.showSettings()
    }

    @objc func showAboutAction(_ sender: Any?) {
        AboutWindowController.shared.showAbout()
    }

    @objc func checkForUpdatesAction(_ sender: Any?) {
        Task { @MainActor in
            await AutoUpdater.shared.checkForUpdates(userInitiated: true)
            UpdateWindowController.shared.showIfUpdateAvailable()
        }
    }
}
