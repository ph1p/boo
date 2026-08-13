import CGhostty
import Cocoa
import SwiftUI

@MainActor protocol PaneViewDelegate: AnyObject {
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

    private(set) var ghosttyView: GhosttyView?
    private var scrollWrapper: TerminalScrollView?
    private var tabViews: [UUID: GhosttyView] = [:]

    /// Generic content view for non-terminal tabs (browser, editor, etc.)
    private(set) var activeContentView: ContentViewProtocol?
    private var contentViews: [UUID: ContentViewProtocol] = [:]

    /// The tab that `ghosttyView` / `activeContentView` actually belong to.
    ///
    /// `pane.activeTab` is NOT a safe key for caching the displayed view: a cross-pane drop
    /// inserts the incoming tab (shifting activeTabIndex) *before* `forceActivateTab` runs
    /// `storeCurrentView`, so the still-displayed view belongs to the previous tab while
    /// `pane.activeTab` already names the incoming one. Caching under that id overwrites the
    /// just-transferred view and the dragged tab's content is lost.
    private var displayedTabID: UUID?

    // Drag state for tab reordering
    var dragTabIndex: Int?
    var dragStartPoint: NSPoint?
    var dragCurrentX: CGFloat?
    let dragThreshold: CGFloat = 5

    // Hover state for tab bar
    var hoveredTabIndex: Int = -1
    var isCloseButtonHovered: Bool = false
    var isPlusButtonHovered: Bool = false
    private var tabBarTrackingArea: NSTrackingArea?

    /// Horizontal scroll offset for tab bar when tabs overflow in scroll mode.
    var tabScrollOffset: CGFloat = 0

    // MARK: - Tab Size Constants
    private let tabMinWidth: CGFloat = 60
    private let tabMaxWidth: CGFloat = 180
    let plusButtonWidth: CGFloat = 32

    /// Tracks last active tab index that triggered auto-scroll, to avoid fighting manual scroll.
    var lastAutoScrolledTabIndex: Int = -1

    /// When true, show the close button even on single-tab panes (e.g. when multiple panes exist).
    var showCloseOnSingleTab = false

    /// Whether tabs should display a close button.
    var showTabClose: Bool { pane.tabs.count > 1 || showCloseOnSingleTab }

    private static let tabMeasureFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// Whether the tab draws a leading icon (content-type icon or process icon)
    /// before its title — `drawSingleTab` gates on the same predicate, so the
    /// measured slot and the drawn content can't disagree.
    func tabHasLeadingIcon(_ tab: Pane.Tab) -> Bool {
        if tab.contentType != .terminal { return true }
        let process = tab.state.foregroundProcess
        return !process.isEmpty && !ProcessIcon.isShell(process) && ProcessIcon.icon(for: process) != nil
    }

    /// Measure the natural width of a single tab slot based on its content:
    /// lead-in + optional icon + title + close/dot zone + pill insets.
    func measuredTabWidth(for tab: Pane.Tab) -> CGFloat {
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let textW = ceil(title.size(withAttributes: [.font: Self.tabMeasureFont]).width)
        var natural = textW + Self.tabTextLeadIn + Self.tabCloseHitZone + Self.tabPillInsetX * 2
        if tabHasLeadingIcon(tab) { natural += Self.tabIconAdvance }
        return min(tabMaxWidth, max(tabMinWidth, natural))
    }

    /// Cached measured widths — `measuredTabWidth` does text layout per title,
    /// and hover/drag paths ask for all widths several times per pointer event.
    /// Keyed by what the measurement depends on (title + icon presence), so it
    /// self-invalidates on any tab change without explicit bookkeeping.
    private var _tabWidthsCache: (key: [String], widths: [CGFloat])?

    /// Compute all tab widths at once (memoized until tab content changes).
    func allTabWidths() -> [CGFloat] {
        let key = pane.tabs.map { "\(Self.tabDisplayTitle(tab: $0))|\(tabHasLeadingIcon($0))" }
        if let cached = _tabWidthsCache, cached.key == key { return cached.widths }
        let widths = pane.tabs.map { measuredTabWidth(for: $0) }
        _tabWidthsCache = (key, widths)
        return widths
    }

    /// Slot start x of tab `index` in scroll mode, before scroll offset.
    func tabStartX(_ index: Int, widths: [CGFloat]) -> CGFloat {
        Self.tabBarSideInset + widths.prefix(index).reduce(0, +)
    }

    /// Computed tab bar height — row stride per row plus the vertical bar
    /// insets, so the outermost pills keep the same margin to the pane edge
    /// as they keep between each other.
    var tabBarHeight: CGFloat {
        let mode = AppSettings.shared.tabOverflowMode
        let rows = mode == .wrap ? wrapRowCount() : 1
        return singleRowTabHeight * CGFloat(rows) + Self.tabBarSideInset * 2
    }

    struct TabLayout {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    /// Compute wrap-mode layout: pills keep their natural width and flow onto
    /// the next row when the current one is full — no stretching.
    func wrapLayout() -> [TabLayout] {
        wrapLayout(widths: allTabWidths())
    }

    /// Cached wrap layout — `tabBarHeight` (and through it `layout()`, `draw()`,
    /// `mouseMoved`, `scrollWheel`, and drag hit-testing) recomputes the full
    /// flow layout on every access, several times per pointer event during a
    /// drag. Keyed by the inputs the layout depends on.
    private var _wrapLayoutCache: (widths: [CGFloat], boundsWidth: CGFloat, layouts: [TabLayout])?

    func wrapLayout(widths: [CGFloat]) -> [TabLayout] {
        let inset = Self.tabBarSideInset
        let availW = bounds.width - inset * 2
        guard !widths.isEmpty, availW > 0 else { return [] }

        if let c = _wrapLayoutCache, c.widths == widths, c.boundsWidth == bounds.width {
            return c.layouts
        }

        var layouts: [TabLayout] = []
        var cx: CGFloat = inset
        var row = 0
        for w in widths {
            if cx - inset + w > availW && cx > inset {
                row += 1
                cx = inset
            }
            layouts.append(TabLayout(x: cx, y: inset + CGFloat(row) * singleRowTabHeight, width: w))
            cx += w
        }
        _wrapLayoutCache = (widths, bounds.width, layouts)
        return layouts
    }

    /// Whether the `+` button fits after the last tab of the given layout, or
    /// has to drop onto a row of its own. Shared by draw, hit-test, and row count.
    func plusFitsOnLastRow(_ layouts: [TabLayout]) -> Bool {
        guard let last = layouts.last else { return true }
        return last.x + last.width + plusButtonWidth <= bounds.width - Self.tabBarSideInset
    }

    /// Number of rows needed in wrap mode.
    private func wrapRowCount() -> Int {
        let layouts = wrapLayout()
        guard let last = layouts.last else { return 1 }
        var rows = Int((last.y - Self.tabBarSideInset) / singleRowTabHeight) + 1
        if !plusFitsOnLastRow(layouts) { rows += 1 }
        return rows
    }

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

    let activityBorder: ActivityBorderOverlay = {
        let v = ActivityBorderOverlay()
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        v.layer?.borderWidth = PaneView.activityBorderWidth
        // Follow the pane's island corner, else the frame squares off the rounding.
        v.layer?.cornerRadius = IslandMetrics.innerRadius
        v.layer?.cornerCurve = .continuous
        return v
    }()

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            focusCatcher.isHidden = isFocused
            updateActivityBorder()
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
        if !activityBorder.isHidden {
            layer.borderColor = theme.accentColor.withAlphaComponent(Self.activityBorderAlpha).cgColor
        } else if isFocused {
            layer.borderColor = theme.focusBorder.cgColor
        } else {
            layer.borderColor = theme.paneBorder.cgColor
        }
    }

    func updateFindBarTheme() {
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
    private var redrawScheduled = false

    // Debounce title/cwd updates during startup to avoid the tab title and
    // file explorer jumping through intermediate states as the shell settles.
    // Keyed per tab: background tabs emit titles/CWDs too, and a single shared slot
    // let one tab's burst cancel and overwrite another tab's pending update.
    private var titleDebounces: [UUID: DispatchWorkItem] = [:]
    private var cwdDebounces: [UUID: DispatchWorkItem] = [:]
    private var pendingTitles: [UUID: String] = [:]
    private var pendingCwds: [UUID: String] = [:]
    private static let debounceInterval: TimeInterval = 0.12

    // MARK: - Find Bar

    private var findBar: FindBarView?
    private var searchMatchTotal: Int = -1

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
        addSubview(activityBorder)
        focusCatcher.onClicked = { [weak self] in
            guard let self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }
        updateOverlayColors()
        updateTabBarTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentTerminalView: NSView? { scrollWrapper ?? ghosttyView }

    /// The currently active content view (terminal or other content type).
    var currentContentView: NSView? {
        if let contentView = activeContentView {
            return contentView
        }
        return scrollWrapper ?? ghosttyView
    }

    // MARK: - Content Lifecycle

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
        // A restored cached surface may re-enter the hierarchy at its previous size, so
        // `ghostty_surface_set_size` does not dirty it and the pane shows stale/blank
        // content until a keystroke or resize. Force a repaint now that layout is done.
        ghosttyView?.refresh()
    }

    /// Cache `gv` for the tab that owns it, or tear it down when that tab has left this pane
    /// (closed, or moved away and already re-homed) — nothing would ever restore it.
    private func retire(_ gv: GhosttyView) {
        gv.removeFromSuperview()
        if let owner = gv.tabID, pane.tabs.contains(where: { $0.id == owner }) {
            tabViews[owner] = gv
        } else {
            gv.destroy()
        }
    }

    /// Content-view counterpart to `retire(_: GhosttyView)`. The owner is passed in because,
    /// unlike `GhosttyView.tabID`, content views carry no tab identity of their own.
    private func retire(_ cv: ContentViewProtocol, owner: UUID?) {
        cv.deactivate()
        cv.removeFromSuperview()
        if let owner, pane.tabs.contains(where: { $0.id == owner }) {
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
            retire(cv, owner: displayedTabID)
        }
        activeContentView = nil
        displayedTabID = tab.id

        if let stored = tabViews.removeValue(forKey: tab.id) {
            scrollWrapper?.removeFromSuperview()
            scrollWrapper = nil
            let wrapper = TerminalScrollView(ghosttyView: stored)
            addSubview(wrapper)
            scrollWrapper = wrapper
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
        scrollWrapper?.removeFromSuperview()
        scrollWrapper = nil
        // A terminal view can never belong to this non-terminal tab, so it is always displaced.
        if let gv = ghosttyView {
            retire(gv)
        }
        ghosttyView = nil

        // Check if the active content view is already for this tab (avoid double-init).
        // Match on the displayed tab id, not just the content type — two tabs of the same
        // kind (e.g. two editors) would otherwise be treated as interchangeable and the
        // incoming tab would keep showing the previous tab's view.
        if let active = activeContentView, active.superview == self, displayedTabID == tab.id,
            active.contentType == tab.contentType
        {
            return
        }

        displayedTabID = tab.id

        // Check cache first
        if let stored = contentViews.removeValue(forKey: tab.id) {
            // Rewire callbacks in case this view was transferred from another pane
            wireContentCallbacks(stored, tabID: tab.id)
            addSubview(stored)
            activeContentView = stored
            stored.activate()
        } else {
            // Create new content view
            let contentView = createContentView(for: tab)
            wireContentCallbacks(contentView, tabID: tab.id)
            addSubview(contentView)
            activeContentView = contentView
            contentView.activate()
        }
    }

    /// Create a content view for the given tab's content type.
    private func createContentView(for tab: Pane.Tab) -> ContentViewProtocol {
        guard tab.contentType != .terminal else {
            fatalError("Use startTerminalSession for terminal tabs")
        }
        return ContentViewFactory.createView(for: tab.state.contentState)
    }

    /// Wire callbacks for non-terminal content views.
    private func wireContentCallbacks(_ contentView: ContentViewProtocol, tabID: UUID) {
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
    func extractGhosttyView(for tabID: UUID) -> GhosttyView? {
        // Check the off-screen cache
        if let gv = tabViews.removeValue(forKey: tabID) {
            gv.removeFromSuperview()
            return gv
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
            // The displayed view is leaving this pane — stop claiming it, or a later
            // storeCurrentView would re-cache a view this pane no longer owns.
            displayedTabID = nil
            return gv
        }
        return nil
    }

    /// Accept a GhosttyView transferred from another pane.
    func insertGhosttyView(_ gv: GhosttyView, for tabID: UUID) {
        tabViews[tabID] = gv
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
        // Just hand over the currently displayed view.
        if let cv = activeContentView {
            cv.deactivate()
            cv.removeFromSuperview()
            activeContentView = nil
            displayedTabID = nil
            return cv
        }
        return nil
    }

    /// Accept a ContentView transferred from another pane.
    func insertContentView(_ cv: ContentViewProtocol, for tabID: UUID) {
        contentViews[tabID] = cv
    }

    func editorView(for tabID: UUID) -> EditorContentView? {
        // Key on the displayed tab, not `pane.activeTab` — after a cross-pane drop those
        // disagree, and this feeds editor lookup/save.
        if displayedTabID == tabID, let activeContentView = activeContentView as? EditorContentView {
            return activeContentView
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
            self.paneDelegate?.paneView(self, commandEnded: exitCode, paneID: self.paneID, tabID: tabID)
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

    func showFindBar() {
        guard pane.activeTab?.contentType == .terminal else { return }
        guard findBar == nil else {
            findBar?.focusField()
            return
        }
        searchMatchTotal = -1
        let bar = FindBarView()
        bar.onSearch = { [weak self] needle in
            self?.ghosttyView?.updateSearch(needle: needle)
        }
        bar.onNavigate = { [weak self] next in
            self?.ghosttyView?.navigateSearch(next: next)
        }
        bar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        findBar = bar
        addSubview(bar)
        layoutTerminalView()
        bar.focusField()
    }

    func hideFindBar() {
        guard let bar = findBar else { return }
        ghosttyView?.endSearch()
        bar.removeFromSuperview()
        findBar = nil
        searchMatchTotal = -1
        layoutTerminalView()
        focusActiveView()
    }

    private func dismissFindBarIfNeeded(forTabAt index: Int) {
        guard isFindBarVisible else { return }
        let targetType = index < pane.tabs.count ? pane.tabs[index].contentType : nil
        if targetType != .terminal {
            ghosttyView?.endSearch()
            findBar?.removeFromSuperview()
            findBar = nil
            searchMatchTotal = -1
        }
    }

    // MARK: - Layout

    func layoutTerminalView() {
        let barH = tabBarHeight
        let findH = findBar != nil ? FindBarView.height : 0
        let newFrame = NSRect(x: 0, y: barH + findH, width: bounds.width, height: max(0, bounds.height - barH - findH))

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
            let barFrame = NSRect(x: 0, y: barH, width: bounds.width, height: FindBarView.height)
            if bar.frame != barFrame { bar.frame = barFrame }
        }

        // Keep both overlays covering the full pane (terminal + tab bar) and above content:
        // dim overlay first (it swallows clicks to focus the pane), activity frame on top so
        // it stays visible on unfocused panes. Adding a content subview buries them, so the
        // order is re-asserted here — checking BOTH slots, since either can slip.
        if focusCatcher.frame != bounds { focusCatcher.frame = bounds }
        if activityBorder.frame != bounds { activityBorder.frame = bounds }
        if subviews.last !== activityBorder || subviews.dropLast().last !== focusCatcher {
            addSubview(focusCatcher, positioned: .above, relativeTo: nil)
            addSubview(activityBorder, positioned: .above, relativeTo: focusCatcher)
        }
    }

    override func layout() {
        super.layout()
        layoutTerminalView()
        updateTabBarTrackingArea()
    }

    // MARK: - Tab Bar Hover Tracking

    func updateTabBarTrackingArea() {
        let newRect = NSRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight)
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
        guard point.y < tabBarHeight else {
            clearTabHover()
            return
        }
        if let idx = tabIndex(at: point) {
            let overClose = isOverCloseButton(point: point, tabIndex: idx)
            if hoveredTabIndex != idx || isPlusButtonHovered || isCloseButtonHovered != overClose {
                hoveredTabIndex = idx
                isCloseButtonHovered = overClose
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

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }

    // MARK: - Tab Management

    /// Activate a tab unconditionally — used after insertTab which already
    /// sets activeTabIndex, making the normal guard in activateTab skip.
    func forceActivateTab(_ index: Int) {
        dismissFindBarIfNeeded(forTabAt: index)
        storeCurrentView()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        focusActiveView()
        if pane.activeTab != nil {
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    func activateTab(_ index: Int) {
        guard index != pane.activeTabIndex else { return }
        dismissFindBarIfNeeded(forTabAt: index)
        storeCurrentView()
        pane.setActivity(false, at: index)
        updateActivityBorder()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        focusActiveView()
        if let tab = pane.activeTab {
            debugLog(
                "[TabSwitch] activateTab(\(index)) pane=\(paneID.uuidString.prefix(8)) title=\(tab.title) process=\(tab.state.foregroundProcess)"
            )
            // Notify delegate of the tab switch so it can restore the bridge
            // state from the tab model. We do NOT fire didChangeDirectory here
            // because the bridge would misinterpret the stale local CWD (set
            // before SSH started) as evidence the remote session ended.
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    /// Focus the appropriate view based on the active tab's content type.
    func focusActiveView() {
        guard let tab = pane.activeTab else { return }
        if tab.contentType == .terminal {
            window?.makeFirstResponder(ghosttyView)
        } else {
            window?.makeFirstResponder(activeContentView)
        }
    }

    @discardableResult
    func addNewTab(workingDirectory: String) -> UUID? {
        addNewTab(contentType: .terminal, workingDirectory: workingDirectory)
    }

    /// Add a new tab with a specific content type.
    @discardableResult
    func addNewTab(contentType: ContentType, workingDirectory: String = "~", url: URL? = nil) -> UUID? {
        storeCurrentView()
        lastAutoScrolledTabIndex = -1

        switch contentType {
        case .terminal:
            _ = pane.addTab(contentType: .terminal, workingDirectory: workingDirectory)
        case .browser:
            _ = pane.addTab(contentType: .browser, workingDirectory: workingDirectory, title: url?.host ?? "New Tab")
        case .editor:
            _ = pane.addTab(contentType: .editor, workingDirectory: workingDirectory)
        case .imageViewer:
            _ = pane.addTab(contentType: .imageViewer, workingDirectory: workingDirectory)
        case .markdownPreview:
            _ = pane.addTab(contentType: .markdownPreview, workingDirectory: workingDirectory)
        case .pluginView:
            _ = pane.addTab(contentType: .pluginView, workingDirectory: workingDirectory, title: "Panel")
        }

        startActiveSession()
        // Trigger single layout + display pass, not redundant calls
        needsLayout = true

        // For browser tabs, navigate to the URL before focus
        if contentType == .browser, let url = url, let browserView = activeContentView as? BrowserContentView {
            browserView.navigate(to: url)
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusActiveView()
        }

        paneDelegate?.paneView(self, didFocus: paneID)
        return pane.tabs.last?.id
    }

    /// Add a plugin-owned SwiftUI view in a new tab.
    @discardableResult
    func addPluginViewTab(view: AnyView, title: String, icon: String) -> UUID? {
        storeCurrentView()
        lastAutoScrolledTabIndex = -1

        _ = pane.addTab(contentType: .pluginView, workingDirectory: "~", title: title)

        startActiveSession()
        needsLayout = true

        // Replace the placeholder content view with the real plugin view.
        // The factory created a placeholder; swap it out before layout.
        activeContentView?.cleanup()
        activeContentView?.removeFromSuperview()
        let pluginView = PluginTabContentView(view: view, title: title, icon: icon)
        activeContentView = pluginView
        addSubview(pluginView)
        needsLayout = true

        window?.makeFirstResponder(pluginView)
        paneDelegate?.paneView(self, didFocus: paneID)
        return pane.tabs.last?.id
    }

    func closeTab(at index: Int) {
        lastAutoScrolledTabIndex = -1
        guard index >= 0, index < pane.tabs.count else { return }
        let tabID = pane.tabs[index].id
        let tab = pane.tabs[index]
        cancelPendingDebounces(for: tabID)

        // Clean up the appropriate view type
        if tab.contentType == .terminal {
            if let gv = tabViews.removeValue(forKey: tabID) { gv.destroy() }
            if pane.activeTabIndex == index {
                ghosttyView?.destroy()
                scrollWrapper?.removeFromSuperview()
                scrollWrapper = nil
                ghosttyView = nil
            }
        } else {
            if let cv = contentViews.removeValue(forKey: tabID) { cv.cleanup() }
            if pane.activeTabIndex == index {
                activeContentView?.cleanup()
                activeContentView?.removeFromSuperview()
                activeContentView = nil
            }
        }

        let wasActive = index == pane.activeTabIndex
        pane.removeTab(at: index)
        if pane.tabs.isEmpty { return }
        if wasActive {
            startActiveSession()
            layoutTerminalView()
            // Focus the appropriate view
            if let newTab = pane.activeTab {
                if newTab.contentType == .terminal {
                    window?.makeFirstResponder(ghosttyView)
                } else {
                    window?.makeFirstResponder(activeContentView)
                }
            }
            if pane.activeTab != nil {
                // Restore bridge state from the newly active tab, same as activateTab.
                paneDelegate?.paneView(self, didFocus: paneID)
            }
        } else {
            layoutTerminalView()
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Drop pending debounced title/CWD updates for one tab (on close).
    /// Updates are keyed per tab, so a tab *switch* needs no cancellation —
    /// each pending item resolves against its own tab.
    private func cancelPendingDebounces(for tabID: UUID) {
        titleDebounces.removeValue(forKey: tabID)?.cancel()
        pendingTitles.removeValue(forKey: tabID)
        cwdDebounces.removeValue(forKey: tabID)?.cancel()
        pendingCwds.removeValue(forKey: tabID)
    }

    private func storeCurrentView() {
        // Cache under the id of the tab each view actually belongs to, never
        // `pane.activeTab` — see `displayedTabID`.
        if let gv = ghosttyView {
            scrollWrapper?.removeFromSuperview()
            scrollWrapper = nil
            ghosttyView = nil
            retire(gv)
        }

        if let cv = activeContentView {
            activeContentView = nil
            retire(cv, owner: displayedTabID)
        }

        displayedTabID = nil
    }

    func persistContentStateToModel() {
        for (index, tab) in pane.tabs.enumerated() where tab.contentType != .terminal {
            // `displayedTabID`, not `pane.activeTab` — a session save right after a
            // cross-pane drop would otherwise persist the displayed view's state under
            // the incoming tab's index.
            if displayedTabID == tab.id, let activeContentView {
                pane.updateContentState(at: index, activeContentView.saveState())
            } else if let contentView = contentViews[tab.id] {
                pane.updateContentState(at: index, contentView.saveState())
            }
        }
    }

    var tabCount: Int { pane.tabs.count }

    // MARK: - Drawing (tab bar)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let overflowMode = AppSettings.shared.tabOverflowMode
        let barH = tabBarHeight

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

    override func accessibilityChildren() -> [Any]? {
        guard !pane.tabs.isEmpty else { return nil }
        let mode = AppSettings.shared.tabOverflowMode
        var elements: [NSAccessibilityElement] = []

        if mode == .wrap {
            let layouts = wrapLayout()
            for (i, tab) in pane.tabs.enumerated() {
                guard i < layouts.count else { break }
                let lay = layouts[i]
                let element = NSAccessibilityElement()
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.radioButton)
                let (_, envPrefix) = Self.environmentIndicator(for: tab.remoteSession)
                element.setAccessibilityLabel("\(envPrefix) \(tab.title)")
                element.setAccessibilityValue((i == pane.activeTabIndex ? 1 : 0) as NSNumber)
                let rect = NSRect(x: lay.x, y: lay.y, width: lay.width, height: singleRowTabHeight)
                let windowRect = convert(rect, to: nil)
                if let screenRect = window?.convertToScreen(windowRect) {
                    element.setAccessibilityFrame(screenRect)
                }
                elements.append(element)
            }
        } else {
            let widths = allTabWidths()
            var tabX: CGFloat = Self.tabBarSideInset - tabScrollOffset
            for (i, tab) in pane.tabs.enumerated() {
                let w = widths[i]
                let element = NSAccessibilityElement()
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.radioButton)
                let (_, envPrefix) = Self.environmentIndicator(for: tab.remoteSession)
                element.setAccessibilityLabel("\(envPrefix) \(tab.title)")
                element.setAccessibilityValue((i == pane.activeTabIndex ? 1 : 0) as NSNumber)
                let rect = NSRect(x: tabX, y: 0, width: w, height: singleRowTabHeight)
                let windowRect = convert(rect, to: nil)
                if let screenRect = window?.convertToScreen(windowRect) {
                    element.setAccessibilityFrame(screenRect)
                }
                elements.append(element)
                tabX += w
            }
        }
        return elements
    }

    // MARK: - Cleanup

    func stopAll() {
        // Clean up terminal views
        for (_, gv) in tabViews { gv.destroy() }
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

    deinit { MainActor.assumeIsolated { stopAll() } }
}
