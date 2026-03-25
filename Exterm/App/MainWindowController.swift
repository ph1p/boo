import CGhostty
import Cocoa
import Combine
import SwiftUI

// SidebarPanelView is added directly to sidebarContainer (no SwiftUI bridge).

/// NSSplitView with themed divider color.
class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        AppSettings.shared.theme.chromeBorder
    }
}

class MainWindowController: NSWindowController, SplitContainerDelegate, NSSplitViewDelegate {
    let appState = AppState()

    let toolbar = ToolbarView(frame: .zero)
    let statusBar = StatusBarView(frame: .zero)
    var statusBarHeightConstraint: NSLayoutConstraint?
    var splitContainer: SplitContainerView!
    var sidebarContainer: NSView!
    var mainSplitView: NSSplitView!

    var sidebarVisible = !AppSettings.shared.sidebarDefaultHidden
    var isRemoteSidebar: Bool {
        get { coordinator?.isRemote ?? false }
        set {  // derived from bridge state, no-op setter for migration
        }
    }
    var currentSidebarPosition: SidebarPosition = .right
    var currentWorkspaceBarPosition: WorkspaceBarPosition = .left
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
    var pluginRegistry: PluginRegistry { coordinator.pluginRegistry }
    /// Set of plugin IDs currently visible in the sidebar stack.
    var openPluginIDs: Set<String> {
        get { coordinator.openPluginIDs }
        set { coordinator.openPluginIDs = newValue }
    }
    /// Track last visible section IDs for skip-rebuild optimization.
    var lastSidebarSectionIDs: [String] = []
    /// Cached detail views per plugin, reused when context hasn't changed.
    var cachedDetailViews: [String: (context: TerminalContext, view: AnyView)] = [:]
    /// Generation counter per plugin — incremented only when the view is recreated.
    var pluginViewGeneration: [String: UInt64] = [:]
    /// Monotonic counter for assigning generations.
    var viewGenerationCounter: UInt64 = 0
    /// Set of plugin IDs currently expanded (not collapsed) in the sidebar.
    var expandedPluginIDs: Set<String> {
        get { coordinator.expandedPluginIDs }
        set { coordinator.expandedPluginIDs = newValue }
    }
    /// Track the previous tab for saving state on switch.
    var previousFocusedTabID: UUID? {
        get { coordinator.previousFocusedTabID }
        set { coordinator.previousFocusedTabID = newValue }
    }
    /// Native sidebar panel view (no SwiftUI hosting).
    var pluginSidebarPanelView: SidebarPanelView?

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

    var activeWorkspace: Workspace? { appState.activeWorkspace }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Exterm"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("ExtermMainWindow")
        window.backgroundColor = AppSettings.shared.theme.chromeBg
        window.appearance = NSAppearance(named: AppSettings.shared.theme.isDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = false

        super.init(window: window)

        setupUI()
        statusBar.sidebarVisible = sidebarVisible
        AppStore.shared.sidebarVisible = sidebarVisible
        setupMenuItems()
        let theBridge = TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "")
        let theRegistry = PluginRegistry()
        coordinator = WindowStateCoordinator(bridge: theBridge, pluginRegistry: theRegistry)
        pluginRegistry.onRequestCycleRerun = { [weak self] in
            guard let self = self else { return }
            // A plugin's internal state changed — clear view cache and force sidebar rebuild.
            self.cachedDetailViews.removeAll()
            self.pluginRegistry.clearChangeDetection()
            self.runPluginCycle(reason: .focusChanged)
        }
        pluginRegistry.registerBuiltins()
        let pluginActions = PluginActions()
        pluginActions.sendToTerminal = { [weak self] in self?.sendRawToActivePane($0) }
        pluginActions.openDirectoryInNewTab = { [weak self] in self?.openDirectoryInNewTab($0) }
        pluginActions.openDirectoryInNewPane = { [weak self] in self?.openDirectoryInNewPane($0) }
        pluginActions.pastePathToActivePane = { [weak self] in self?.pastePathToActivePane($0) }
        pluginRegistry.actions = pluginActions
        pluginRegistry.hostActions = PluginHostActions(
            pastePathToActivePane: { [weak self] in self?.pastePathToActivePane($0) },
            openDirectoryInNewTab: { [weak self] in self?.openDirectoryInNewTab($0) },
            openDirectoryInNewPane: { [weak self] in self?.openDirectoryInNewPane($0) },
            sendRawToActivePane: { [weak self] in self?.sendRawToActivePane($0) }
        )
        pluginRegistry.registerStatusBarIcons(in: statusBar)
        tabDragCoordinator.onDrop = { [weak self] source, tabIndex, dest, zone in
            self?.handleTabDrop(source: source, tabIndex: tabIndex, dest: dest, zone: zone)
        }
        restoreWorkspaces()
        subscribeToBridge()
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

            // Theme changes: refresh chrome colors, pane backgrounds, sidebar, status bar
            if topic == nil || topic == .theme {
                MainActor.assumeIsolated { AppStore.shared.refreshTheme() }
                let theme = AppSettings.shared.theme
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
                if !self.openPluginIDs.isEmpty {
                    let registry = self.pluginRegistry
                    Task { @MainActor in
                        if let ctx = registry.lastContext {
                            self.rebuildPluginSidebar(context: ctx)
                        }
                    }
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
            }

            // Plugin default changes: sync live sidebar to match new defaults.
            // Rebuild openPluginIDs from scratch: start with new defaults, keep auto-opened ones.
            if topic == .plugins {
                let newDefaults = Set(AppSettings.shared.defaultEnabledPluginIDs)
                // Keep plugins that were auto-opened (not in any defaults list)
                let autoOpened = self.openPluginIDs.filter { !newDefaults.contains($0) }
                self.openPluginIDs = newDefaults.union(autoOpened)
                self.cachedDetailViews.removeAll()
                MainActor.assumeIsolated { self.pluginRegistry.clearChangeDetection() }
            }

            // Explorer/plugin changes: refresh sidebar via a cycle
            if topic == nil || topic == .explorer || topic == .plugins {
                if self.sidebarVisible {
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

        sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor

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
        statusBar.onSidebarPluginToggle = { [weak self] pluginID in
            self?.togglePluginInSidebar(pluginID)
        }
        statusBar.onSidebarToggle = { [weak self] in
            self?.toggleSidebarAction(nil)
        }
        contentView.addSubview(statusBar)

        currentWorkspaceBarPosition = AppSettings.shared.workspaceBarPosition

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

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitView.adjustSubviews()
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
                self.refreshStatusBar()
            }
            .store(in: &bridgeCancellables)

        // When a process registers/unregisters via the socket, re-evaluate.
        ExtermSocketServer.shared.onStatusChanged = { [weak self] in
            guard let self else { return }
            self.bridge.reevaluateSocketProcess()
        }

        bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .directoryChanged:
                    self.schedulePluginCycle(reason: .cwdChanged)

                case .titleChanged:
                    self.schedulePluginCycle(reason: .titleChanged)

                case .processChanged:
                    self.schedulePluginCycle(reason: .processChanged)

                case .remoteSessionChanged:
                    self.syncRemoteSidebarState()
                    self.schedulePluginCycle(reason: .remoteSessionChanged)

                case .focusChanged:
                    self.refreshToolbar()
                    self.schedulePluginCycle(reason: .focusChanged)

                case .workspaceSwitched:
                    self.refreshToolbar()
                    self.schedulePluginCycle(reason: .workspaceSwitched)

                case .remoteDirectoryListed(let path, let entries):
                    self.pluginRegistry.notifyRemoteDirectoryListed(path: path, entries: entries)
                    self.schedulePluginCycle(reason: .cwdChanged)
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
        openWorkspace(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @objc func openFolderAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open as a workspace"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openWorkspace(path: url.path)
        }
    }

    @objc func newTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let cwd = workspace.folderPath
        pv.addNewTab(workingDirectory: cwd)
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        sidebarVisible.toggle()
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

    @objc func checkForUpdatesAction(_ sender: Any?) {
        Task { @MainActor in
            await AutoUpdater.shared.checkForUpdates(userInitiated: true)
            UpdateWindowController.shared.showIfUpdateAvailable()
        }
    }
}
