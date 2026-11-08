import CGhostty
import Cocoa
import Combine
import SwiftUI

@MainActor class MainWindowController: NSWindowController, SplitContainerDelegate, NSSplitViewDelegate, NSWindowDelegate
{
    let appState = AppState()

    let toolbar = ToolbarView(frame: .zero)
    let statusBar = StatusBarView(frame: .zero)
    var statusBarHeightConstraint: NSLayoutConstraint?
    var toolbarHeightConstraint: NSLayoutConstraint?
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
    /// Set while the orchestrator drawer is open in this window.
    var orchestratorDrawer: OrchestratorDrawerView?

    /// PaneViews keyed by workspace ID → pane ID → PaneView
    var workspacePaneViews: [UUID: [UUID: PaneView]] = [:]
    /// Panes of the active workspace that mirror each other's typing.
    var broadcast: BroadcastGroup?
    /// Workspace whose split tree is currently rendered in the split container.
    var renderedWorkspaceID: UUID?
    /// Other window highlighted as the drop target while a workspace is dragged out of this one.
    weak var workspaceDragTarget: MainWindowController?
    /// Overlay shown on this window while another window drags a workspace over it.
    var workspaceDropHighlight: NSView?
    /// Inline name/color editor currently shown for a workspace pill.
    var workspaceEditorPopover: NSPopover?

    /// Convenience accessor for current workspace's pane views.
    var paneViews: [UUID: PaneView] {
        get {
            guard let id = activeWorkspace?.id else { return [:] }
            return workspacePaneViews[id] ?? [:]
        }
        set {
            guard let id = activeWorkspace?.id else { return }
            workspacePaneViews[id] = newValue
        }
    }
    nonisolated(unsafe) private var settingsObserver: Any?
    nonisolated(unsafe) private var ghosttyActionObserver: Any?
    nonisolated(unsafe) private var ghosttyOpenURLObserver: Any?
    nonisolated(unsafe) var screenParametersObserver: Any?
    var coordinator: WindowStateCoordinator!
    var bridge: TerminalBridge! { coordinator.bridge }
    nonisolated(unsafe) var bridgeCancellables = Set<AnyCancellable>()
    let contextAnnouncer = ContextAnnouncementEngine()

    /// Coalesced plugin cycle scheduling — batches rapid-fire events within one run loop tick.
    var pendingCycleReason: PluginCycleReason?
    var cycleScheduled = false
    private var cycleRerunScheduled = false

    /// Pending image sends keyed by tab ID, waiting for a live shell PID.
    /// `failedPID` is the PID that last failed — only retry with a different PID.
    /// Background agent tabs to show once their command starts, by tab ID.
    var pendingReveals: [UUID: () -> Void] = [:]
    var pendingImageSends: [UUID: (path: String, size: ghostty_surface_size_s?, failedPID: pid_t)] = [:]

    /// Registry of factories for named custom tab types (registerMultiContentTab API).
    var multiContentTabFactories: [String: (PluginTabContext) -> AnyView] = [:]
    /// Maps tabID → "typeID:key" for deduplication in openMultiContentTab.
    var registeredTabKeys: [UUID: String] = [:]

    /// Focus debounce — prevents sidebar rebuild from causing a focus feedback loop.
    var lastFocusedPaneID: UUID?
    /// Active tab at the time of the last honoured focus event. The debounce must not
    /// swallow a focus event for a *different* tab in the same pane (e.g. a brand-new
    /// tab), or the bridge keeps the previous tab's remote session and title.
    var lastFocusedTabID: UUID?
    var allowNextWindowClose = false
    /// Whether this window writes the session file. Fresh and restored windows
    /// start without it (their init would otherwise overwrite the session file
    /// before every window exists); `WindowManager.register` turns it on.
    var persistsSession: Bool
    /// Launch window restores the saved session; extra windows start fresh.
    private let restoresSession: Bool
    /// Saved window to restore (multi-window launch). nil with `restoresSession`
    /// loads the first window of the session file.
    let restoredWindow: SessionWindow?
    /// Live workspace dragged in from another window; opened instead of a
    /// default workspace during setup.
    private var pendingAdoption: DetachedWorkspace?
    /// Frame before entering fullscreen, saved instead of the fullscreen frame.
    var windowedFrame: NSRect?
    /// Last settled placement: becomes `homePlacement` if its display disappears.
    var lastPlacement: WindowPlacement?
    /// Placement on a display that is gone; reapplied when it reconnects.
    var homePlacement: WindowPlacement?
    var placementCommit: DispatchWorkItem?
    /// Debounce timer for saving the session after split-pane divider drags.
    var splitRatioSaveTimer: Timer?
    /// Debounce timer for saving workspace sidebar state after sidebar divider drags.
    var sidebarStateSaveTimer: Timer?
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

    func cancelPendingSidebarStateSave() {
        sidebarStateSaveTimer?.invalidate()
        sidebarStateSaveTimer = nil
    }

    var cachedDetailViews: [String: (context: TerminalContext, generations: [UInt64])] {
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

    var displacedPluginTabID: String? {
        get { sidebarController?.displacedPluginTabID }
        set { sidebarController?.displacedPluginTabID = newValue }
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

    /// CWD for which a background git-detect walk is currently in flight.
    /// Prevents duplicate concurrent walks for the same directory.
    var gitDetectInFlightCWD: String?

    deinit {
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = ghosttyActionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = ghosttyOpenURLObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = screenParametersObserver { NotificationCenter.default.removeObserver(obs) }
        bridgeCancellables.removeAll()
    }

    /// Undo stack for closed tabs and panes
    enum ClosedItem {
        case tab(paneID: UUID, workingDirectory: String, index: Int)
        case pane(siblingPaneID: UUID, workingDirectory: String, direction: SplitTree.SplitDirection)

        /// Pane the entry reopens into.
        var paneID: UUID {
            switch self {
            case .tab(let paneID, _, _): return paneID
            case .pane(let siblingPaneID, _, _): return siblingPaneID
            }
        }
    }
    var undoStack: [ClosedItem] = []

    var activeRemoteSession: RemoteSessionType? {
        coordinator?.activeRemoteSession
    }

    var pluginWatcher: PluginWatcher?

    func notifyTerminalClosed(for terminalID: UUID) {
        pluginRegistry.notifyTerminalClosed(terminalID: terminalID)
        OrchestratorEvents.shared.terminalClosed(terminalID)
        pendingImageSends.removeValue(forKey: terminalID)
        // Clean up stale scroll offsets for the closed terminal.
        // Coordinator is authoritative; panel copy is cleaned to stay in sync.
        let prefix = "\(terminalID.uuidString):"
        coordinator?.sidebarScrollOffsets =
            coordinator?.sidebarScrollOffsets.filter {
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

    /// Apply Boo chrome settings to an NSWindow.
    static func applyWindowChrome(_ window: NSWindow, autosaveFrame: Bool) {
        window.title = "Boo"
        window.minSize = NSSize(width: 600, height: 400)
        // Only the launch window remembers its frame; extra windows cascade
        // from the key window instead of stacking on the saved frame.
        if autosaveFrame { window.setFrameAutosaveName("BooMainWindow") }
        // Boo has its own workspace bar; native window tabs would nest a second one.
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = AppSettings.shared.theme.windowBackdrop
        window.appearance = NSAppearance(named: AppSettings.shared.theme.isDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = false
    }

    /// - Parameters:
    ///   - restoreSession: launch window: load the saved session and remember the
    ///     frame; otherwise start with a single default workspace.
    ///   - sessionWindow: restore this saved window instead of loading the file.
    ///   - adopting: workspace moved in from another window (live panes).
    init(
        restoreSession: Bool = true, restoring sessionWindow: SessionWindow? = nil,
        adopting detached: DetachedWorkspace? = nil
    ) {
        restoresSession = detached == nil && (restoreSession || sessionWindow != nil)
        restoredWindow = sessionWindow
        pendingAdoption = detached
        persistsSession = restoreSession && sessionWindow == nil
        let window = BooWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        Self.applyWindowChrome(window, autosaveFrame: restoreSession)
        homePlacement = Self.applySavedPlacement(sessionWindow, to: window)
        super.init(window: window)
        performSetup()
        startPlacementTracking()
    }

    private func performSetup() {
        // Initialize coordinator and sidebar controller before UI setup
        let theBridge = TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "")
        let theRegistry = PluginRegistry()
        coordinator = WindowStateCoordinator(bridge: theBridge, pluginRegistry: theRegistry)
        sidebarController = SidebarController(windowController: self)
        if let state = restoredWindow?.sidebarState {
            sidebarController.seedWindowState(state)
        }

        setupUI()
        statusBar.sidebarVisible = sidebarVisible
        AppStore.shared.sidebarVisible = sidebarVisible
        setupMenuItems()
        pluginRegistry.onRequestCycleRerun = { [weak self] in
            guard let self, !self.cycleRerunScheduled else { return }
            // A plugin's internal state changed — clear view cache and force sidebar rebuild.
            // Coalesced to one forced cycle per runloop turn: a git refresh fans out to
            // several plugins, each requesting its own rerun.
            self.cycleRerunScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cycleRerunScheduled = false
                self.cachedDetailViews.removeAll()
                self.pluginRegistry.clearChangeDetection()
                self.runPluginCycle(reason: .focusChanged)
            }
        }
        pluginRegistry.registerBuiltins()
        // Keep status bar branch cache in sync with GitPlugin's .git/HEAD watcher.
        // This ensures the branch updates immediately after git switch/checkout without
        // waiting for a CWD change event.
        if let gitPlugin = pluginRegistry.plugin(for: "git-panel") as? GitPlugin {
            gitPlugin.onBranchChanged = { [weak self] branch, repoRoot in
                guard let self else { return }
                let cwd = self.statusBar.currentDirectory
                booLog(
                    .debug, .git,
                    "onBranchChanged: branch=\(branch ?? "nil") repoRoot=\(repoRoot ?? "nil") statusBar.cwd=\(cwd)")
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
        installPluginActions()
        tabDragCoordinator.onDrop = { [weak self] source, tabIndex, dest, zone in
            self?.handleTabDrop(source: source, tabIndex: tabIndex, dest: dest, zone: zone)
        }
        tabDragCoordinator.onWorkspaceHover = { [weak self] index in
            guard let self, index != self.appState.activeWorkspaceIndex else { return }
            self.activateWorkspace(index)
        }
        tabDragCoordinator.workspacePillFrames = { [weak self] in
            self?.workspacePillScreenFrames() ?? []
        }
        tabDragCoordinator.paneViewsAtScreenPoint = { [weak self] point in
            self?.dropTargetPaneViews(atScreenPoint: point)
        }
        tabDragCoordinator.onDropOutside = { [weak self] source, tabIndex, point in
            self?.tearOffTab(source: source, tabIndex: tabIndex, atScreenPoint: point)
        }
        if let detached = pendingAdoption {
            pendingAdoption = nil
            adoptWorkspace(detached)
        } else if restoresSession {
            restoreWorkspaces()
        } else {
            openWorkspace(path: AppSettings.shared.defaultFolder)
        }
        subscribeToBridge()
        // Socket / remote-control handlers are app-wide: WindowManager installs them once.
        setupPluginWatcher()

        // Run initial plugin cycle so lastContext is available for first click
        DispatchQueue.main.async { [weak self] in
            self?.runPluginCycle(reason: .focusChanged)
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let topicString = notification.userInfo?["topic"] as? String
            MainActor.assumeIsolated {
                // Minimized windows still apply changes: nothing replays them on restore.
                guard let self, let window = self.window, window.isVisible || window.isMiniaturized else { return }
                let topic = topicString.flatMap(SettingsTopic.init(rawValue:))
                self.applySettingsChange(topic)
            }  // end MainActor.assumeIsolated
        }

        ghosttyActionObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyAction, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                let action = info["action"] as? String
            else { return }
            let targetWindow = Self.windowID(of: notification)
            guard MainActor.assumeIsolated({ self.handlesWindowScoped(targetWindow) }) else { return }
            let direction = info["direction"] as? String
            let safeInfo: [String: String] = direction.map { ["direction": $0] } ?? [:]
            Task { @MainActor [weak self] in self?.handleGhosttyAction(action, userInfo: safeInfo) }
        }

        ghosttyOpenURLObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyOpenURL, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                let url = notification.userInfo?["url"] as? URL
            else { return }
            let targetWindow = Self.windowID(of: notification)
            MainActor.assumeIsolated {
                guard self.handlesWindowScoped(targetWindow) else { return }
                switch AppSettings.shared.linkOpenMode {
                case .browserTab:
                    self.handleOpenTab(.browser(url: url))
                case .externalBrowser:
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Ghostty posts surface actions with the surface's window as `object`;
    /// app-level actions (no surface) carry nil and go to the active window only.
    func handlesWindowScoped(_ targetWindow: ObjectIdentifier?) -> Bool {
        if let targetWindow { return window.map(ObjectIdentifier.init) == targetWindow }
        return WindowManager.shared.activeController.map { $0 === self } ?? true
    }

    nonisolated private static func windowID(of notification: Notification) -> ObjectIdentifier? {
        (notification.object as? NSWindow).map(ObjectIdentifier.init)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }
        window.delegate = self
        contentView.wantsLayer = true
        // Backdrop the islands float on — visible in every gap between them.
        contentView.layer?.backgroundColor = AppSettings.shared.theme.windowBackdrop.cgColor

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.delegate = self
        // Not an island: no fill, no border, no rounding — a bare strip over the backdrop.
        contentView.addSubview(toolbar)

        mainSplitView = ThemedSplitView()
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.delegate = self
        (mainSplitView as? ThemedSplitView)?.onDividerDoubleClick = { [weak self] in
            self?.resetSidebarWidthToDefault()
        }
        contentView.addSubview(mainSplitView)

        splitContainer = SplitContainerView(frame: .zero)
        splitContainer.splitDelegate = self
        splitContainer.onRatioChanged = { [weak self] updatedTree in
            guard let self, let workspaceID = self.renderedWorkspaceID else { return }
            guard self.appState.replaceSplitTree(for: workspaceID, with: updatedTree) else {
                debugLog(
                    "[WorkspaceSwitch] ignoredSplitRatio workspace=\(workspaceID.uuidString) activeWorkspace=\(self.activeWorkspace?.id.uuidString ?? "none")"
                )
                return
            }
            if workspaceID != self.activeWorkspace?.id {
                debugLog(
                    "[WorkspaceSwitch] applySplitRatio renderedWorkspace=\(workspaceID.uuidString) activeWorkspace=\(self.activeWorkspace?.id.uuidString ?? "none")"
                )
            }
            self.scheduleSplitRatioSave()
        }

        sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor
        IslandMetrics.round(sidebarContainer, borderColor: AppSettings.shared.theme.sidebarBorder)

        // Sidebar tab bar
        let tabBar = SidebarTabBarView(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] tab in
            guard let self, let ctx = self.pluginRegistry.lastContext else { return }
            self.displacedPluginTabID = nil
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
        sidebarController.position = currentSidebarPosition
        if sidebarVisible {
            addSplitSubviewsInSidebarOrder()
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
            self.displacedPluginTabID = nil
            self.activatePluginTab(SidebarTabID(pluginID), context: ctx)
        }
        // Not an island: no fill, no border, no rounding — a bare strip over the backdrop.
        contentView.addSubview(statusBar)

        currentWorkspaceBarPosition = AppSettings.shared.workspaceBarPosition
        currentTabOverflowMode = AppSettings.shared.tabOverflowMode

        // Toolbar, panes and status bar share one `gap` side inset so their content
        // lines up; the side workspace bar adjusts the leading/trailing constraints.
        // The thin bars use the tighter `barGap` vertically.
        let gap = IslandMetrics.gap
        let barGap = IslandMetrics.barGap
        let toolbarLeading = toolbar.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: gap)
        let toolbarTrailing = toolbar.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -gap)
        let mainSplitLeading = mainSplitView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: gap)
        let mainSplitTrailing = mainSplitView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -gap)
        toolbarLeadingConstraint = toolbarLeading
        toolbarTrailingConstraint = toolbarTrailing
        mainSplitLeadingConstraint = mainSplitLeading
        mainSplitTrailingConstraint = mainSplitTrailing

        let headerHeight = IslandMetrics.toolbarHeight(for: currentWorkspaceBarPosition)
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: headerHeight)
        toolbarHeightConstraint = toolbarHeight

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: barGap),
            toolbarLeading,
            toolbarTrailing,
            toolbarHeight,

            mainSplitView.topAnchor.constraint(
                equalTo: toolbar.bottomAnchor, constant: IslandMetrics.headerBottomGap),
            mainSplitLeading,
            mainSplitTrailing,
            mainSplitView.bottomAnchor.constraint(
                equalTo: statusBar.topAnchor, constant: -IslandMetrics.footerTopGap),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: gap),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -gap),
            statusBar.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -IslandMetrics.footerBottomGap)
        ])

        if currentWorkspaceBarPosition == .left || currentWorkspaceBarPosition == .right {
            setupSideWorkspaceBar(in: contentView, position: currentWorkspaceBarPosition)
        }
        let heightConstraint = statusBar.heightAnchor.constraint(
            equalToConstant: DensityMetrics.current.statusBarHeight)
        heightConstraint.isActive = true
        statusBarHeightConstraint = heightConstraint

        TrafficLightPositioner.attach(to: window, headerHeight: headerHeight)

    }

    // MARK: - SplitContainerDelegate

    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView {
        if let existing = paneViews[paneID] {
            return existing
        }

        guard let workspace = activeWorkspace else {
            let fallbackPane = Pane(id: paneID)
            _ = fallbackPane.addTab(workingDirectory: AppSettings.shared.defaultFolder)
            return makePaneView(paneID: paneID, pane: fallbackPane)
        }

        workspace.normalizePaneState()
        guard let pv = paneView(for: paneID, in: workspace) else {
            debugLog(
                "[WorkspaceSwitch] missingPaneView workspace=\(workspace.id.uuidString) pane=\(paneID.uuidString)"
            )
            let fallbackPane = Pane(id: paneID)
            _ = fallbackPane.addTab(workingDirectory: workspace.folderPath)
            return makePaneView(paneID: paneID, pane: fallbackPane)
        }
        return pv
    }

    /// The pane view of `paneID` in `workspace`, created and cached on first
    /// use; works for inactive workspaces too. Nil when the pane is gone.
    func paneView(for paneID: UUID, in workspace: Workspace) -> PaneView? {
        if let existing = workspacePaneViews[workspace.id]?[paneID] { return existing }
        guard let pane = workspace.pane(for: paneID) else { return nil }
        let pv = makePaneView(paneID: paneID, pane: pane)
        workspacePaneViews[workspace.id, default: [:]][paneID] = pv
        return pv
    }

    private func makePaneView(paneID: UUID, pane: Pane) -> PaneView {
        let pv = PaneView(paneID: paneID, pane: pane)
        pv.paneDelegate = self
        pv.tabDragCoordinator = tabDragCoordinator
        return pv
    }

    // MARK: - Termination save

    /// Synchronous final save on window close (fires before `applicationWillTerminate` returns):
    /// `saveSession()` writes in the background, so this flush guarantees the final state on disk.
    func windowWillClose(_ notification: Notification) {
        if hasOrchestratorDrawer { OrchestratorController.shared.closeDrawer() }
        coordinator?.saveSidebarStateToSettings()
        // Persist all live state to the model synchronously, then write synchronously.
        for paneView in paneViews.values {
            paneView.persistContentStateToModel()
        }
        normalizeWorkspaceState()
        persistActiveWorkspaceSidebarState()
        savePluginStateForActiveTab()
        let manager = WindowManager.shared
        guard manager.isManaged(self) else {
            if persistsSession { SessionStore.save(appState: appState) }
            return
        }
        // Quitting or closing the last window: the session keeps this window.
        if manager.isTerminating || manager.controllers.count == 1 {
            manager.writeSession(from: self, sync: true)
            if !manager.isTerminating {
                manager.remove(self)
                destroyParkedTmuxGateways()
                // Settings is an auxiliary window: left open it would keep the app
                // alive with no terminal window. Closing it lets the app quit.
                for w in NSApp.windows where w.windowController is SettingsWindowController {
                    w.close()
                }
            }
            return
        }
        // The app keeps running when other windows remain: stop this window's
        // terminals so they don't outlive it, drop it from the session, then let
        // it deallocate.
        tearDownAllWorkspaces()
        manager.remove(self)
        if let next = manager.controllers.first {
            manager.writeSession(from: next, sync: true)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        windowedFrame = window?.frame
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        windowedFrame = nil
    }

    /// This window's session entry. Main thread only.
    func sessionWindow() -> SessionWindow {
        var entry = SessionStore.buildWindow(appState: appState, agents: agentResumePoints())
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if let placement = currentPlacement() {
            entry.frame = placement.frame
            entry.screenID = placement.screenID
            entry.screenFrame = placement.screenFrame
        }
        rememberDisplacedPlacement(in: PlacementScreen.current)
        entry.homePlacement = homePlacement
        entry.isFullScreen = isFullScreen
        let sidebar = sidebarController.windowState
        entry.sidebarIsVisible = sidebar.isVisible
        entry.sidebarWidth = sidebar.width.map { Double($0) }
        return entry
    }

    private func tearDownAllWorkspaces() {
        destroyParkedTmuxGateways()
        for ws in appState.workspaces {
            for pane in ws.panes.values {
                notifyTerminalClosed(for: pane.tabs)
            }
        }
        for views in workspacePaneViews.values {
            for pv in views.values {
                pv.stopAll()
            }
        }
        workspacePaneViews.removeAll()
    }
}
