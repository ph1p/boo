import CGhostty
import Cocoa
import SwiftUI

@MainActor protocol PaneViewDelegate: AnyObject {
    /// `paneView` shows a tmux pane, which holds only its own tab: open the
    /// new tab elsewhere and return its ID.
    func paneView(
        _ paneView: PaneView, redirectNewTab contentType: ContentType, workingDirectory: String, url: URL?,
        launch: LaunchSpec?
    ) -> UUID?
    func paneView(_ paneView: PaneView, redirectPluginView view: AnyView, title: String, icon: String) -> UUID?
    func paneView(_ paneView: PaneView, didFocus paneID: UUID)
    func paneView(_ paneView: PaneView, didChangeDirectory path: String, paneID: UUID)
    func paneView(_ paneView: PaneView, titleChanged title: String, paneID: UUID)
    func paneView(_ paneView: PaneView, foregroundProcessChanged name: String, paneID: UUID)
    func paneView(
        _ paneView: PaneView, remoteStateChanged session: RemoteSessionType?, remoteCwd: String?, paneID: UUID)
    func paneView(_ paneView: PaneView, remoteConnectionFailed session: RemoteSessionType, paneID: UUID)
    func paneView(_ paneView: PaneView, sessionEnded paneID: UUID)
    func paneView(_ paneView: PaneView, directoryListing path: String, output: String, paneID: UUID)
    func paneView(_ paneView: PaneView, didRequestCloseTab index: Int, paneID: UUID)
    func paneView(_ paneView: PaneView, shellPIDDiscovered pid: pid_t, paneID: UUID, tabID: UUID?)
    func paneView(_ paneView: PaneView, commandStarted command: String, paneID: UUID, tabID: UUID?)
    func paneView(_ paneView: PaneView, commandEnded exitCode: Int32, paneID: UUID, tabID: UUID?)
    /// A tab's OSC 9;4 progress changed (already stored on the pane).
    func paneView(_ paneView: PaneView, progressChangedIn paneID: UUID)
    /// Terminal bell (BEL) fired in the given pane.
    func paneView(_ paneView: PaneView, bellRangIn paneID: UUID, tabID: UUID?)
    /// OSC 777/99 desktop notification request from the given pane.
    func paneView(
        _ paneView: PaneView,
        desktopNotificationTitle title: String,
        body: String,
        paneID: UUID,
        tabID: UUID?
    )
    func paneView(_ paneView: PaneView, didRequestMoveTab index: Int, toWorkspaceAt workspaceIndex: Int, paneID: UUID)
    func paneView(
        _ paneView: PaneView, didRequestMoveGroup groupID: UUID, toWorkspaceAt workspaceIndex: Int, paneID: UUID)
    /// Moves a whole tab group into a new split beside its pane.
    func paneView(_ paneView: PaneView, didRequestSplitGroup groupID: UUID, paneID: UUID)
    /// Closes every tab in a group after one confirmation.
    func paneView(_ paneView: PaneView, didRequestCloseGroup groupID: UUID, paneID: UUID)
    func paneViewWorkspaceNames(_ paneView: PaneView) -> [(index: Int, name: String)]
    /// Returns true if this pane is the only pane in its workspace (used for close-label wording).
    func paneViewIsOnlyPaneInWorkspace(_ paneView: PaneView) -> Bool
}

/// A pane: optional tab bar on top + GhosttyView below.
/// Each tab has its own Ghostty surface. CWD and process tracking
/// comes exclusively from Ghostty's action callbacks (OSC 7, title).
class PaneView: NSView {
    let paneID: UUID
    weak var paneDelegate: PaneViewDelegate?
    weak var tabDragCoordinator: TabDragCoordinator?

    let pane: Pane
    /// Row stride in wrap mode: pill height plus a half-gap above and below, so
    /// stacked rows sit one full gap apart (matching the horizontal pill gap).
    let singleRowTabHeight: CGFloat = PaneView.tabPillHeight + PaneView.tabPillInsetX * 2

    var ghosttyView: GhosttyView?
    var scrollWrapper: TerminalScrollView?
    /// A terminal tab that isn't displayed. Its `wrapper`, when kept, stays
    /// attached but hidden: a tab switch then unhides the surface instead of
    /// re-attaching it to the window.
    @MainActor struct CachedTerminal {
        let view: GhosttyView
        let wrapper: TerminalScrollView?

        /// Detach the cached terminal from this pane.
        func detach() {
            wrapper?.removeFromSuperview()
            view.removeFromSuperview()
        }

        /// Close the cached terminal for good.
        func discard() {
            wrapper?.removeFromSuperview()
            view.destroy()
        }
    }
    var tabViews: [UUID: CachedTerminal] = [:]

    /// Generic content view for non-terminal tabs (browser, editor, etc.)
    var activeContentView: ContentViewProtocol?
    var contentViews: [UUID: ContentViewProtocol] = [:]

    /// Running reorder slide of the tab pills (see PaneView+TabSlide).
    var tabSlide: TabSlide?
    var tabSlideLink: CADisplayLink?

    // Drag state for tab reordering
    var dragTabIndex: Int?
    var dragStartPoint: NSPoint?
    var dragCurrentX: CGFloat?
    let dragThreshold: CGFloat = 5

    // Group chip press/drag: a click toggles collapse, a drag moves the group.
    var groupPressID: UUID?
    var groupPressPoint: NSPoint?
    /// Insertion index while a group is being dragged (nil until past threshold).
    var groupDropIndex: Int?

    /// Tabs picked with ⌘-click for grouping. Transient, never persisted.
    var selectedTabIDs: Set<UUID> = []
    var groupEditorPopover: NSPopover?

    // Hover state for tab bar
    var hoveredTabIndex: Int = -1
    var isCloseButtonHovered: Bool = false
    /// The pointer is on the group chip of `hoveredTabIndex`.
    var isGroupChipHovered: Bool = false
    var isPlusButtonHovered: Bool = false
    private var tabBarTrackingArea: NSTrackingArea?

    /// Horizontal scroll offset for tab bar when tabs overflow in scroll mode.
    var tabScrollOffset: CGFloat = 0

    // MARK: - Tab Size Constants
    let tabMinWidth: CGFloat = 72
    let tabMaxWidth: CGFloat = 220
    /// Slot for the `+`: its pill is as wide as it is tall.
    let plusButtonWidth: CGFloat = PaneView.tabPillHeight + 2 * PaneView.tabPillInsetX

    /// Tracks last active tab index that triggered auto-scroll, to avoid fighting manual scroll.
    var lastAutoScrolledTabIndex: Int = -1

    /// When true, show the close button even on single-tab panes (e.g. when multiple panes exist).
    var showCloseOnSingleTab = false {
        didSet {
            guard showCloseOnSingleTab != oldValue else { return }
            updatePaneControls()
        }
    }

    /// Whether tabs should display a close button.
    var showTabClose: Bool { pane.tabs.count > 1 || showCloseOnSingleTab }

    /// Cached measured widths — `measuredTabWidth` does text layout per title,
    /// and hover/drag paths ask for all widths several times per pointer event.
    /// Keyed by what the measurement depends on (title + icon presence), so it
    /// self-invalidates on any tab change without explicit bookkeeping.
    var _tabWidthsCache: (key: [String], widths: [CGFloat])?

    /// Cached wrap layout — `tabBarHeight` (and through it `layout()`, `draw()`,
    /// `mouseMoved`, `scrollWheel`, and drag hit-testing) recomputes the full
    /// flow layout on every access, several times per pointer event during a
    /// drag. Keyed by the inputs the layout depends on.
    var _wrapLayoutCache: (widths: [CGFloat], boundsWidth: CGFloat, layouts: [TabLayout])?

    /// Invisible overlay covering an unfocused pane so the first click focuses it
    /// (the click still passes through). Purely a click-catcher — the focused pane
    /// is marked by its island stroke tint, not by dimming its siblings.
    private class FocusCatcherOverlay: NSView {
        var onClicked: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            onClicked?()
            super.mouseDown(with: event)
        }
    }

    private let focusCatcher: FocusCatcherOverlay = {
        let v = FocusCatcherOverlay()
        v.autoresizingMask = [.width, .height]
        return v
    }()

    static let activityBorderWidth: CGFloat = 2
    private static let activityBorderAlpha: CGFloat = 0.8

    /// Transparent, click-through frame drawn around the whole pane while it has
    /// pending activity. `draw(_:)` can't do this: terminal/content subviews cover
    /// everything below the tab bar, so a border painted by the pane itself is hidden.
    /// Internal (not private) so tests can inspect it directly.
    class ActivityBorderOverlay: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Hidden, click-through frame that follows the pane's island corner
    /// (else the frame squares off the rounding).
    private static func makeBorderOverlay() -> ActivityBorderOverlay {
        let v = ActivityBorderOverlay()
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        v.layer?.borderWidth = PaneView.activityBorderWidth
        v.layer?.cornerRadius = IslandMetrics.innerRadius
        v.layer?.cornerCurve = .continuous
        return v
    }

    let activityBorder = PaneView.makeBorderOverlay()

    /// Orange frame on every pane that receives broadcast input; shown even
    /// on the focused pane, since typing into the wrong host is the accident.
    let broadcastBorder: ActivityBorderOverlay = {
        let v = PaneView.makeBorderOverlay()
        v.layer?.borderColor = BroadcastSegment.color.cgColor
        return v
    }()

    var isBroadcasting: Bool {
        get { !broadcastBorder.isHidden }
        set { broadcastBorder.isHidden = !newValue }
    }

    /// Red frame while the front tab records, so it's clear which split is captured.
    let recordingBorder = PaneView.makeBorderOverlay()

    /// ⋯ notch with record / split / zoom / close in the pane's bottom-right corner.
    let paneControls = PaneControlsView()
    /// Pointer-in-pane tracking for `paneControls`; its own owner so the tab
    /// bar's enter/exit handling stays untouched.
    let paneHoverTracker = PaneHoverTracker()
    var isPointerInPane = false
    /// Whether `paneControls` currently shows.
    var paneControlsShown = false
    /// The island edge drawn around the notch's cut while it shows. A view,
    /// not a sublayer, so it shares the pane's flipped coordinates.
    final class IslandCutStroke: NSView {
        var path: CGPath? { didSet { needsDisplay = true } }
        var color: NSColor = .clear { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let path, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(IslandMetrics.borderWidth)
            ctx.strokePath()
        }
    }

    let islandCutStroke: IslandCutStroke = {
        let v = IslandCutStroke()
        v.isHidden = true
        return v
    }()
    private var paneSettingsObserver: NSObjectProtocol?

    /// Surface and window frame at the last surface refresh. A split or close
    /// refreshes only panes whose surface, frame or attachment changed since.
    struct SurfaceRefreshKey: Equatable {
        let surface: ObjectIdentifier
        let frame: NSRect
    }
    var lastSurfaceRefresh: SurfaceRefreshKey?

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            focusCatcher.isHidden = isFocused
            updateActivityBorder()
            updatePaneControls()
            needsDisplay = true
        }
    }

    /// Show/hide the pane-wide activity frame. Push-driven: called from the sites that
    /// change focus or a tab's `hasActivity` flag (`isFocused`, `activateTab`,
    /// `MainWindowController.markActivity`) — never from `draw(_:)`, which must stay
    /// pure paint and would otherwise re-derive this on every tab-bar repaint.
    func updateActivityBorder() {
        activityBorder.isHidden = isFocused || !pane.tabs.contains { $0.state.hasActivity }
        syncIslandStroke()
    }

    /// The pane is an island, so its own layer carries a hairline stroke — and a
    /// layer's border paints *above* its sublayers, which would hide the outermost
    /// pixels of the activity overlay. Tint the island stroke with the same accent
    /// while activity shows so the frame reads as one solid accent edge; the
    /// focused pane gets a softer accent tint instead of dimming its siblings.
    func syncIslandStroke() {
        guard let layer else { return }
        let theme = AppSettings.shared.theme
        if !recordingBorder.isHidden {
            layer.borderColor = theme.error.withAlphaComponent(0.8).cgColor
        } else if !activityBorder.isHidden {
            layer.borderColor = theme.accentColor.withAlphaComponent(Self.activityBorderAlpha).cgColor
        } else if isFocused {
            layer.borderColor = theme.focusBorder.cgColor
        } else {
            layer.borderColor = theme.paneBorder.cgColor
        }
        if let c = layer.borderColor { islandCutStroke.color = NSColor(cgColor: c) ?? .clear }
    }

    func updateFindBarTheme() {
        paneControls.applyTheme()
        recordingBorder.layer?.borderColor = AppSettings.shared.theme.error.withAlphaComponent(0.8).cgColor
        findBar?.applyTheme()
        findBar?.needsDisplay = true
    }

    /// Restyle every overlay for the current theme. Wired into the theme-change loop in
    /// `MainWindowController`; without the accent refresh here a visible activity frame
    /// keeps the old theme's accent.
    func updateOverlayColors() {
        let theme = AppSettings.shared.theme
        activityBorder.layer?.borderColor =
            theme.accentColor.withAlphaComponent(Self.activityBorderAlpha).cgColor
        syncIslandStroke()
    }

    // Coalesce tab bar redraws to avoid flicker from rapid title updates
    var redrawScheduled = false

    // Debounce title/cwd updates during startup to avoid the tab title and
    // file explorer jumping through intermediate states as the shell settles.
    // Keyed per tab: background tabs emit titles/CWDs too, and a single shared slot
    // let one tab's burst cancel and overwrite another tab's pending update.
    var titleDebounces: [UUID: DispatchWorkItem] = [:]
    var cwdDebounces: [UUID: DispatchWorkItem] = [:]
    var pendingTitles: [UUID: String] = [:]
    var pendingCwds: [UUID: String] = [:]
    static let debounceInterval: TimeInterval = 0.12

    // MARK: - Zoom

    /// True while this pane is zoomed (its workspace's other panes are hidden).
    /// The corner notch then carries an unzoom button.
    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            updatePaneControls()
            needsLayout = true
        }
    }

    /// Called when the notch's unzoom button is clicked.
    var onUnzoomRequested: (() -> Void)?

    /// Per tab: clears a progress bar nobody updated for `TerminalProgress.staleAfter`.
    var progressExpiry: [UUID: DispatchWorkItem] = [:]

    // MARK: - Find Bar

    var findBar: FindBarView?
    var searchMatchTotal: Int = -1
    /// Browser tab the find bar searches, nil while it drives the terminal.
    weak var findBrowser: BrowserContentView?
    /// Repaints agent status in vertical tab rows.
    private var agentInboxObserver: NSObjectProtocol?

    var isFindBarVisible: Bool { findBar != nil }

    init(paneID: UUID, pane: Pane) {
        self.paneID = paneID
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
        // Each pane is an island: rounding here also clips the terminal's
        // Metal sublayer, which libghostty owns and we can't round directly.
        IslandMetrics.round(
            self, radius: IslandMetrics.innerRadius,
            borderColor: AppSettings.shared.theme.paneBorder)
        addSubview(focusCatcher)
        addSubview(broadcastBorder)
        addSubview(activityBorder)
        recordingBorder.layer?.borderColor = AppSettings.shared.theme.error.withAlphaComponent(0.8).cgColor
        addSubview(recordingBorder)
        paneControls.isHidden = true
        paneControls.alphaValue = 0
        addSubview(islandCutStroke)
        paneControls.onUnzoom = { [weak self] in self?.onUnzoomRequested?() }
        paneControls.onResize = { [weak self] in self?.updatePaneControls() }
        addSubview(paneControls)
        paneHoverTracker.onChange = { [weak self] inside in
            self?.isPointerInPane = inside
            self?.updatePaneControls()
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: paneHoverTracker))
        paneSettingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] note in
            // Pane controls and recording settings all post `.layout`; nil is a full reload.
            let topic = (note.userInfo?["topic"] as? String).flatMap(SettingsTopic.init(rawValue:))
            guard topic == nil || topic == .layout else { return }
            MainActor.assumeIsolated { self?.updatePaneControls() }
        }
        focusCatcher.onClicked = { [weak self] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }
        updateOverlayColors()
        updateTabBarTrackingArea()
        agentInboxObserver = NotificationCenter.default.addObserver(
            forName: .agentInboxChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Vertical rows show the agent's status line; horizontal tabs badge it.
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentTerminalView: NSView? { scrollWrapper ?? ghosttyView }

    // MARK: - Layout

    func layoutTerminalView() {
        let barH = tabBarHeight
        let colW = verticalTabColumnWidth
        let findH = findBar != nil ? FindBarView.height : 0
        let newFrame = NSRect(
            x: colW, y: barH + findH, width: max(0, bounds.width - colW), height: max(0, bounds.height - barH - findH))

        // Layout terminal view if present
        if let container: NSView = scrollWrapper ?? ghosttyView {
            if container.frame != newFrame { container.frame = newFrame }
        }

        // Layout content view if present (browser, editor, etc.)
        if let contentView = activeContentView {
            if contentView.frame != newFrame { contentView.frame = newFrame }
        }

        // Layout find bar just above tab bar
        if let bar = findBar {
            let barFrame = NSRect(x: colW, y: barH, width: max(0, bounds.width - colW), height: FindBarView.height)
            if bar.frame != barFrame { bar.frame = barFrame }
        }

        // Keep both overlays covering the full pane (terminal + tab bar) and above content:
        // dim overlay first (it swallows clicks to focus the pane), activity frame on top so
        // it stays visible on unfocused panes. Adding a content subview buries them, so the
        // order is re-asserted here — checking BOTH slots, since either can slip.
        // The corner notch sits above all of them, in the bottom-right corner.
        if focusCatcher.frame != bounds { focusCatcher.frame = bounds }
        if activityBorder.frame != bounds { activityBorder.frame = bounds }
        if broadcastBorder.frame != bounds { broadcastBorder.frame = bounds }
        if recordingBorder.frame != bounds { recordingBorder.frame = bounds }
        let controlsSize = paneControls.frame.size
        let controlsFrame = NSRect(
            x: bounds.width - controlsSize.width, y: bounds.height - controlsSize.height,
            width: controlsSize.width, height: controlsSize.height)
        if paneControls.frame != controlsFrame { paneControls.frame = controlsFrame }
        syncIslandCut()
        let overlays: [NSView] = [
            focusCatcher, broadcastBorder, activityBorder, recordingBorder, paneControls, islandCutStroke
        ]
        if !zip(subviews.suffix(overlays.count), overlays).allSatisfy({ $0 === $1 }) {
            for overlay in overlays { addSubview(overlay, positioned: .above, relativeTo: nil) }
        }
    }

    override func layout() {
        super.layout()
        layoutTerminalView()
        updateTabBarTrackingArea()
    }

    // MARK: - Tab Bar Hover Tracking

    func updateTabBarTrackingArea() {
        let newRect = tabBarRect
        guard tabBarTrackingArea?.rect != newRect else { return }
        if let existing = tabBarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: newRect,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tabBarTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInTabBar(point) else {
            clearTabHover()
            return
        }
        if let idx = tabIndex(at: point) {
            let overChip = groupChipHit(at: point, tabIndex: idx) != nil
            let overClose = !overChip && isOverCloseButton(point: point, tabIndex: idx)
            if hoveredTabIndex != idx || isPlusButtonHovered || isCloseButtonHovered != overClose
                || isGroupChipHovered != overChip
            {
                hoveredTabIndex = idx
                isCloseButtonHovered = overClose
                isGroupChipHovered = overChip
                isPlusButtonHovered = false
                needsDisplay = true
            }
        } else if isPlusButtonHit(at: point) {
            // Over plus button
            if !isPlusButtonHovered || hoveredTabIndex != -1 {
                hoveredTabIndex = -1
                isCloseButtonHovered = false
                isPlusButtonHovered = true
                needsDisplay = true
            }
        } else {
            clearTabHover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearTabHover()
    }

    private func clearTabHover() {
        if hoveredTabIndex != -1 || isPlusButtonHovered || isCloseButtonHovered {
            hoveredTabIndex = -1
            isCloseButtonHovered = false
            isPlusButtonHovered = false
            needsDisplay = true
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Re-parented surfaces may not repaint on their own, even at the same size.
        lastSurfaceRefresh = nil
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }

    // MARK: - Drawing (tab bar)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let overflowMode = AppSettings.shared.tabOverflowMode
        let barH = tabBarHeight
        if overflowMode == .vertical {
            drawTabsVertical(ctx: ctx, theme: theme)
            return
        }

        // Tab bar background — same as the terminal below, so the pills read as
        // sitting inside the pane rather than on a separate chrome strip.
        ctx.setFillColor(theme.background.nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: barH))

        if overflowMode == .wrap {
            drawTabsWrapped(ctx: ctx, theme: theme)
        } else {
            drawTabsScrollable(ctx: ctx, theme: theme, barH: barH)
        }

        // No bottom border — the bar shares the terminal background, so the
        // pills float directly inside the pane with nothing separating them.

        // The pane-wide activity frame is NOT drawn here — content subviews cover
        // everything below the tab bar. See `activityBorder` / `updateActivityBorder()`.
    }

    // MARK: - Tab Bar Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? {
        .tabGroup
    }

    override func accessibilityLabel() -> String? { "Tabs" }

    /// Drawn tabs plus the real subviews: returning only the tabs would hide
    /// the terminal and other content views from VoiceOver.
    override func accessibilityChildren() -> [Any]? {
        let content = super.accessibilityChildren() ?? []
        guard !pane.tabs.isEmpty else { return content }
        var elements: [Any] = []
        for (i, tab) in pane.tabs.enumerated() {
            guard !pane.isTabHidden(at: i), let rect = tabSlotRect(at: i) else { continue }
            let (_, envPrefix) = Self.environmentIndicator(for: tab.remoteSession)
            let groupSuffix = pane.group(id: tab.groupID).map { ", group \($0.name)" } ?? ""
            let title = Self.tabDisplayTitle(tab: tab)
            let label = (envPrefix.isEmpty ? title : "\(envPrefix) \(title)") + groupSuffix
            let tabID = tab.id
            elements.append(
                AccessibleElement(
                    parent: self, role: .radioButton, label: label, localRect: rect,
                    selected: i == pane.activeTabIndex
                ) { [weak self] in
                    guard let self, let idx = self.pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                    self.activateTab(idx)
                    self.focusActiveView()
                })
        }
        elements.append(
            AccessibleElement(parent: self, role: .button, label: "New tab", localRect: plusButtonSlot()) {
                [weak self] in
                guard let self else { return }
                self.addNewTab(
                    contentType: .terminal, workingDirectory: self.pane.activeTab?.workingDirectory ?? "~",
                    group: self.activeGroupID)
            })
        return elements + content
    }

    /// Terminal views by tab ID, for saving scrollback on quit.
    var terminalViewsByTab: [UUID: GhosttyView] {
        var views = tabViews.mapValues(\.view)
        if let gv = ghosttyView, let id = gv.tabID { views[id] = gv }
        return views
    }

    // MARK: - Cleanup

    func stopAll() {
        // Clean up terminal views
        for cached in tabViews.values {
            cached.discard()
        }
        tabViews.removeAll()
        ghosttyView?.destroy()
        scrollWrapper?.removeFromSuperview()
        scrollWrapper = nil
        ghosttyView = nil

        // Clean up content views
        for (_, cv) in contentViews { cv.cleanup() }
        contentViews.removeAll()
        activeContentView?.cleanup()
        activeContentView?.removeFromSuperview()
        activeContentView = nil
    }

    deinit {
        MainActor.assumeIsolated {
            if let agentInboxObserver { NotificationCenter.default.removeObserver(agentInboxObserver) }
            if let paneSettingsObserver { NotificationCenter.default.removeObserver(paneSettingsObserver) }
            stopAll()
        }
    }
}
