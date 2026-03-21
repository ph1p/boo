import CGhostty
import Cocoa

protocol PaneViewDelegate: AnyObject {
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
    func paneView(_ paneView: PaneView, shellPIDDiscovered pid: pid_t, paneID: UUID)
}

/// A pane: optional tab bar on top + GhosttyView below.
/// Each tab has its own Ghostty surface. CWD and process tracking
/// comes exclusively from Ghostty's action callbacks (OSC 7, title).
class PaneView: NSView {
    let paneID: UUID
    weak var paneDelegate: PaneViewDelegate?
    weak var tabDragCoordinator: TabDragCoordinator?

    let pane: Pane
    let singleRowTabHeight: CGFloat = 26

    private var ghosttyView: GhosttyView?
    private var scrollWrapper: TerminalScrollView?
    private var tabViews: [UUID: GhosttyView] = [:]

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
    private let tabMinWidth: CGFloat = 100
    private let tabMaxWidth: CGFloat = 180
    private let tabHPadding: CGFloat = 28  // left content margin + close button zone
    let plusButtonWidth: CGFloat = 32

    /// Tracks last active tab index that triggered auto-scroll, to avoid fighting manual scroll.
    var lastAutoScrolledTabIndex: Int = -1

    /// When true, show the close button even on single-tab panes (e.g. when multiple panes exist).
    var showCloseOnSingleTab = false

    /// Whether tabs should display a close button.
    var showTabClose: Bool { pane.tabs.count > 1 || showCloseOnSingleTab }

    /// Measure the natural width of a single tab based on its title content.
    func measuredTabWidth(for tab: Pane.Tab) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium)
        ]
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let textW = title.size(withAttributes: attrs).width
        let dotAndGap: CGFloat = 20  // env dot + gap
        let natural = dotAndGap + textW + tabHPadding
        return min(tabMaxWidth, max(tabMinWidth, natural))
    }

    /// Compute all tab widths at once (cached per draw cycle via callers).
    func allTabWidths() -> [CGFloat] {
        pane.tabs.map { measuredTabWidth(for: $0) }
    }

    /// Computed tab bar height — single row normally, multiple rows in wrap mode.
    var tabBarHeight: CGFloat {
        let mode = AppSettings.shared.tabOverflowMode
        guard mode == .wrap else { return singleRowTabHeight }
        let rows = wrapRowCount()
        return singleRowTabHeight * CGFloat(rows)
    }

    struct TabLayout {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    /// Compute wrap-mode layout: tabs distributed across rows, stretched to fill width.
    func wrapLayout() -> [TabLayout] {
        let widths = allTabWidths()
        let availW = bounds.width
        guard !widths.isEmpty, availW > 0 else { return [] }

        // First pass: assign to rows by natural width
        var rows: [[Int]] = [[]]
        var rowW: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if rowW + w > availW && rowW > 0 {
                rows.append([i])
                rowW = w
            } else {
                rows[rows.count - 1].append(i)
                rowW += w
            }
        }

        // Check if plus button fits on last row
        let lastRowW = rows.last.map { $0.reduce(0.0) { $0 + widths[$1] } } ?? 0
        let plusOnLastRow = lastRowW + plusButtonWidth <= availW

        // Second pass: stretch each row to fill width
        var layouts = [TabLayout](repeating: TabLayout(x: 0, y: 0, width: 0), count: widths.count)
        for (rowIdx, row) in rows.enumerated() {
            let isLastRow = rowIdx == rows.count - 1
            let naturalSum = row.reduce(0.0) { $0 + widths[$1] }
            let stretchTarget = isLastRow && plusOnLastRow ? availW - plusButtonWidth : availW
            let scale = naturalSum > 0 ? stretchTarget / naturalSum : 1
            var cx: CGFloat = 0
            for idx in row {
                let w = widths[idx] * scale
                layouts[idx] = TabLayout(x: cx, y: CGFloat(rowIdx) * singleRowTabHeight, width: w)
                cx += w
            }
        }
        return layouts
    }

    /// Number of rows needed in wrap mode.
    private func wrapRowCount() -> Int {
        let widths = allTabWidths()
        var rows = 1
        var rowX: CGFloat = 0
        let availW = bounds.width
        for w in widths {
            if rowX + w > availW && rowX > 0 {
                rows += 1
                rowX = w
            } else {
                rowX += w
            }
        }
        // Plus button
        if rowX + plusButtonWidth > availW && rowX > 0 { rows += 1 }
        return max(1, rows)
    }

    // Coalesce tab bar redraws to avoid flicker from rapid title updates
    private var redrawScheduled = false

    init(paneID: UUID, pane: Pane) {
        self.paneID = paneID
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
        updateTabBarTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentTerminalView: NSView? { scrollWrapper ?? ghosttyView }

    // MARK: - Terminal Lifecycle

    func startActiveSession() {
        guard let tab = pane.activeTab else { return }

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
            let gv = GhosttyView(workingDirectory: tab.workingDirectory)
            wireCallbacks(gv)
            let wrapper = TerminalScrollView(ghosttyView: gv)
            addSubview(wrapper)
            scrollWrapper = wrapper
            ghosttyView = gv
        }
        layoutTerminalView()
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
        // Just hand over the currently displayed view.
        if let gv = ghosttyView {
            // Remove from scroll wrapper without destroying
            gv.removeFromSuperview()
            scrollWrapper?.removeFromSuperview()
            scrollWrapper = nil
            ghosttyView = nil
            return gv
        }
        return nil
    }

    /// Accept a GhosttyView transferred from another pane.
    func insertGhosttyView(_ gv: GhosttyView, for tabID: UUID) {
        tabViews[tabID] = gv
    }

    private func wireCallbacks(_ gv: GhosttyView) {
        gv.onFocused = { [weak self] in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }

        gv.onPwdChanged = { [weak self] path in
            guard let self = self else { return }
            let idx = self.pane.activeTabIndex
            if idx >= 0 { self.pane.updateWorkingDirectory(at: idx, path) }
            self.scheduleTabBarRedraw()
            self.paneDelegate?.paneView(self, didChangeDirectory: path, paneID: self.paneID)
        }

        gv.onTitleChanged = { [weak self] title in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, titleChanged: title, paneID: self.paneID)

            let idx = self.pane.activeTabIndex
            if idx >= 0 { self.pane.updateTitle(at: idx, title) }
            self.scheduleTabBarRedraw()
        }

        gv.onDirectoryListing = { [weak self] path, output in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, directoryListing: path, output: output, paneID: self.paneID)
        }

        gv.onProcessExited = { [weak self] in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, sessionEnded: self.paneID)
        }

        gv.onShellPIDDiscovered = { [weak self] pid in
            guard let self = self else { return }
            let idx = self.pane.activeTabIndex
            if idx >= 0 { self.pane.updateShellPID(at: idx, pid) }
            self.paneDelegate?.paneView(self, shellPIDDiscovered: pid, paneID: self.paneID)
        }
    }

    // MARK: - Layout

    func layoutTerminalView() {
        let container: NSView? = scrollWrapper ?? ghosttyView
        guard let view = container else { return }
        let barH = tabBarHeight
        let newFrame = NSRect(x: 0, y: barH, width: bounds.width, height: max(0, bounds.height - barH))
        if view.frame != newFrame { view.frame = newFrame }
    }

    override func layout() {
        super.layout()
        layoutTerminalView()
        updateTabBarTrackingArea()
        needsDisplay = true
    }

    // MARK: - Tab Bar Hover Tracking

    func updateTabBarTrackingArea() {
        if let existing = tabBarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight),
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

    /// Coalesce rapid title/cwd updates into a single redraw per run loop cycle.
    private func scheduleTabBarRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
        storeCurrentView()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        window?.makeFirstResponder(ghosttyView)
        if pane.activeTab != nil {
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    func activateTab(_ index: Int) {
        guard index != pane.activeTabIndex else { return }
        storeCurrentView()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        window?.makeFirstResponder(ghosttyView)
        if let tab = pane.activeTab {
            NSLog(
                "[PaneView] activateTab(\(index)): title=\(tab.title), cwd=\(tab.workingDirectory), remote=\(String(describing: tab.remoteSession)), remoteCwd=\(String(describing: tab.remoteWorkingDirectory))"
            )
            // Notify delegate of the tab switch so it can restore the bridge
            // state from the tab model. We do NOT fire didChangeDirectory here
            // because the bridge would misinterpret the stale local CWD (set
            // before SSH started) as evidence the remote session ended.
            paneDelegate?.paneView(self, didFocus: paneID)
        }
    }

    func addNewTab(workingDirectory: String) {
        storeCurrentView()
        lastAutoScrolledTabIndex = -1
        _ = pane.addTab(workingDirectory: workingDirectory)
        startActiveSession()
        layoutTerminalView()
        needsLayout = true
        needsDisplay = true
        paneDelegate?.paneView(self, didFocus: paneID)
        // Defer focus to next run-loop tick so the view hierarchy is fully installed
        DispatchQueue.main.async { [weak self] in
            guard let self, let gv = self.ghosttyView else { return }
            self.window?.makeFirstResponder(gv)
        }
    }

    func closeTab(at index: Int) {
        lastAutoScrolledTabIndex = -1
        let tabID = pane.tabs[index].id
        if let gv = tabViews.removeValue(forKey: tabID) { gv.destroy() }
        if pane.activeTabIndex == index {
            ghosttyView?.destroy()
            scrollWrapper?.removeFromSuperview()
            scrollWrapper = nil
            ghosttyView = nil
        }

        let wasActive = index == pane.activeTabIndex
        pane.removeTab(at: index)
        if pane.tabs.isEmpty { return }
        if wasActive {
            startActiveSession()
            layoutTerminalView()
            window?.makeFirstResponder(ghosttyView)
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

    private func storeCurrentView() {
        guard let gv = ghosttyView, let tab = pane.activeTab else { return }
        gv.removeFromSuperview()
        scrollWrapper?.removeFromSuperview()
        scrollWrapper = nil
        tabViews[tab.id] = gv
        ghosttyView = nil
    }

    var tabCount: Int { pane.tabs.count }

    // MARK: - Drawing (tab bar)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let overflowMode = AppSettings.shared.tabOverflowMode
        let barH = tabBarHeight
        let termBgColor = theme.background.nsColor.cgColor

        // Tab bar background
        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: barH))

        if overflowMode == .wrap {
            drawTabsWrapped(ctx: ctx, theme: theme, barH: barH, termBgColor: termBgColor)
        } else {
            drawTabsScrollable(ctx: ctx, theme: theme, barH: barH, termBgColor: termBgColor)
        }

        // Row separator borders in wrap mode (between rows)
        if overflowMode == .wrap {
            let rows = Int(barH / singleRowTabHeight)
            ctx.setFillColor(theme.chromeBorder.cgColor)
            for r in 1..<rows {
                let borderY = CGFloat(r) * singleRowTabHeight - 1
                ctx.fill(CGRect(x: 0, y: borderY, width: bounds.width, height: 1))
            }
        }

        // Full-width bottom border (1px, same style as sidebar separator)
        ctx.setFillColor(theme.chromeBorder.cgColor)
        ctx.fill(CGRect(x: 0, y: barH - 1, width: bounds.width, height: 1))

        // Active tab breaks the border to connect to the terminal below
        let activeIdx = pane.activeTabIndex
        if activeIdx >= 0 && activeIdx < pane.tabs.count {
            var ax: CGFloat = 0
            var aw: CGFloat = 0
            var onBottomRow = true
            if overflowMode == .wrap {
                let layouts = wrapLayout()
                if activeIdx < layouts.count {
                    let lay = layouts[activeIdx]
                    ax = lay.x
                    aw = lay.width
                    onBottomRow = lay.y == barH - singleRowTabHeight
                }
            } else {
                let widths = allTabWidths()
                for i in 0..<activeIdx { ax += widths[i] }
                ax -= tabScrollOffset
                aw = widths[activeIdx]
            }
            if onBottomRow {
                // Clamp the break so it never erases the border under the plus button
                let maxBreakRight = overflowMode == .scroll ? bounds.width - plusButtonWidth : bounds.width
                let clampedRight = min(ax + aw, maxBreakRight)
                let clampedLeft = min(ax, maxBreakRight)
                let breakW = max(0, clampedRight - clampedLeft)
                if breakW > 0 {
                    ctx.setFillColor(termBgColor)
                    ctx.fill(CGRect(x: clampedLeft, y: barH - 1, width: breakW, height: 1))
                }
            }
        }
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
            var tabX: CGFloat = -tabScrollOffset
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
        for (_, gv) in tabViews { gv.destroy() }
        tabViews.removeAll()
        ghosttyView?.destroy()
        scrollWrapper?.removeFromSuperview()
        scrollWrapper = nil
        ghosttyView = nil
    }

    deinit { stopAll() }
}
