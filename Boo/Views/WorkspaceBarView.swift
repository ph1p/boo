import Cocoa

@MainActor protocol WorkspaceBarViewDelegate: AnyObject {
    func workspaceBar(_ bar: WorkspaceBarView, didSelectAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, didCloseAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, togglePinForWorkspaceAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceFrom source: Int, to destination: Int)
    /// Workspace `source` was dropped onto the pill at `target`: group them.
    func workspaceBar(_ bar: WorkspaceBarView, stackWorkspaceAt source: Int, onto target: Int)
    /// Workspace `source` was dropped onto a group header.
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceAt source: Int, intoGroup groupID: String)
    /// A workspace was dragged out and released outside this window.
    func workspaceBar(_ bar: WorkspaceBarView, dropWorkspaceAt index: Int, atScreenPoint point: NSPoint)
    /// A dragged workspace moved; `point` is the screen point when outside this window, nil otherwise or when the drag ends.
    func workspaceBar(_ bar: WorkspaceBarView, workspaceDragMovedOutsideTo point: NSPoint?)
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceToNewWindowAt index: Int)
    func workspaceBarDidRequestNewWorkspace(_ bar: WorkspaceBarView)
    /// Extra items for a workspace's context menu, shown above Close.
    func workspaceBar(_ bar: WorkspaceBarView, contextMenuItemsForWorkspaceAt index: Int) -> [NSMenuItem]
    /// Open the inline name/color editor for a workspace, anchored on `rect` in the bar.
    func workspaceBar(_ bar: WorkspaceBarView, editWorkspaceAt index: Int, anchor rect: NSRect)
    /// A workspace-group header (or a collapsed group's pill) was clicked.
    func workspaceBar(_ bar: WorkspaceBarView, toggleGroup groupID: String)
    /// A group header was dragged to insertion index `destination` (whole group moves).
    func workspaceBar(_ bar: WorkspaceBarView, moveGroup groupID: String, to destination: Int)
    /// A group header was dropped outside the window.
    func workspaceBar(_ bar: WorkspaceBarView, dropGroup groupID: String, atScreenPoint point: NSPoint)
    /// Context menu for a workspace-group header.
    func workspaceBar(_ bar: WorkspaceBarView, menuItemsForGroup groupID: String) -> [NSMenuItem]
}

extension WorkspaceBarViewDelegate {
    func workspaceBar(_ bar: WorkspaceBarView, contextMenuItemsForWorkspaceAt index: Int) -> [NSMenuItem] { [] }
    func workspaceBar(_ bar: WorkspaceBarView, editWorkspaceAt index: Int, anchor rect: NSRect) {}
    func workspaceBar(_ bar: WorkspaceBarView, toggleGroup groupID: String) {}
    func workspaceBar(_ bar: WorkspaceBarView, moveGroup groupID: String, to destination: Int) {}
    func workspaceBar(_ bar: WorkspaceBarView, dropGroup groupID: String, atScreenPoint point: NSPoint) {}
    func workspaceBar(_ bar: WorkspaceBarView, stackWorkspaceAt source: Int, onto target: Int) {}
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceAt source: Int, intoGroup groupID: String) {}
    func workspaceBar(_ bar: WorkspaceBarView, menuItemsForGroup groupID: String) -> [NSMenuItem] { [] }
}

class WorkspaceBarView: NSView {
    weak var delegate: WorkspaceBarViewDelegate?

    /// When true, draws workspace items stacked vertically.
    /// Always true in the app — the bar only ever renders as a side strip, with
    /// top-bar workspaces drawn by `ToolbarView` instead. Kept as a property because
    /// the setup path sets it explicitly and `hitTest`/`draw` bail out until it is.
    var isVertical: Bool = false
    /// When true, the vertical bar is on the right edge (separator on left).
    var isRightAligned: Bool = false

    static let workspaceIndexPBType = NSPasteboard.PasteboardType("com.boo.workspaceIndex")

    struct Item {
        let name: String
        let path: String
        var isPinned: Bool = false
        var color: WorkspaceColor = .none
        var hasCustomColor: Bool = false
        var resolvedColor: NSColor? = nil
        /// Unseen activity in a background workspace (same rule as the top bar).
        var hasActivity: Bool = false
        var progress: TerminalProgress?
        /// Workspace group this item belongs to. Members of one group are expected to
        /// be contiguous; the controller keeps them that way.
        var groupID: String? = nil
        var groupName: String? = nil
        var groupCollapsed: Bool = false
        var groupColor: NSColor? = nil
    }

    /// One workspace group as laid out in the strip. `top`/`height` (the header) and
    /// `trayHeight` (the tinted container around header and visible members, starting
    /// `groupTrayPadding` above the header) are in content space, before the scroll offset. An expanded group
    /// gets a short chevron + name header row; a collapsed one is drawn as a single
    /// pill-sized folder.
    struct GroupHeader {
        let id: String
        let name: String
        let collapsed: Bool
        let members: Range<Int>
        let top: CGFloat
        let height: CGFloat
        let trayHeight: CGFloat
        /// Unseen activity in a member hidden by the collapse.
        let hiddenActivity: Bool
        /// User-picked group color, nil for the neutral default.
        var color: NSColor? = nil
    }

    /// Row layout, rebuilt by `setItems`. `rowTops[i]` is item i's content-space top.
    /// Items hidden in a collapsed group keep the top of the next visible slot so
    /// drop-index math still has something sane to compare against.
    private(set) var rowTops: [CGFloat] = []
    private(set) var hiddenRows: Set<Int> = []
    private(set) var groupHeaders: [GroupHeader] = []

    /// Height of an expanded group's header row (chevron + short name).
    static let groupHeaderHeight: CGFloat = 20
    nonisolated(unsafe) static let groupLabelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    nonisolated(unsafe) static let groupCountFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

    private(set) var items: [Item] = []
    private(set) var selectedIndex: Int = -1

    private let barHeight: CGFloat = 32
    var dragSourceIndex: Int?
    var dropTargetIndex: Int?
    /// Pill the drag would stack onto (forming or joining its group).
    var dropStackIndex: Int?
    /// Group header the drag would join.
    var dropGroupID: String?
    /// Group whose header is being dragged (the whole group moves).
    var draggedGroupID: String?

    // Ghost drag state
    var ghostWindow: DragGhostWindow?
    var isDragging: Bool = false

    // Hover state
    var hoveredIndex: Int = -1
    /// Group whose header (or collapsed folder) is under the cursor.
    var hoveredGroupID: String?
    var isPlusButtonHovered: Bool = false
    /// Pointer is over the expanded pill's close button (draws its hover circle).
    var isCloseButtonHovered: Bool = false
    var wsBarTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateWSBarTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated { cleanupDrag() }
    }

    /// Horizontal inset of a pill inside the vertical strip.
    static let verticalPadding: CGFloat = 5

    /// Width the strip *claims* in the window layout — what the panes sit clear of.
    /// One number, shared with the layout code in `MainWindowController`.
    static let verticalWidth: CGFloat = 46

    /// Extra width the view's frame carries beyond `verticalWidth`, used only as
    /// scratch space for the expanded hover pill. The panes are laid out against
    /// `verticalWidth`, so this band overlaps them — the view sits above the split
    /// view and `hitTest` lets anything not on the expanded pill fall through.
    static let verticalHoverOverhang: CGFloat = 140

    /// Total frame width of the view: the visible strip plus the overhang the
    /// expanded hover pill floats into.
    static let verticalFrameWidth: CGFloat = verticalWidth + verticalHoverOverhang

    /// X where the visible strip starts inside the frame. On a right-side bar the
    /// overhang is on the left, so the strip is pushed to the far edge.
    var verticalStripX: CGFloat {
        isRightAligned ? bounds.width - Self.verticalWidth : 0
    }

    /// Width of a resting pill — the strip minus its padding.
    var verticalPillWidth: CGFloat {
        Self.verticalWidth - Self.verticalPadding * 2
    }

    /// X of a resting pill in the strip.
    var verticalPillX: CGFloat { verticalStripX + Self.verticalPadding }

    /// Narrowest the expanded hover pill gets. Short names still read as a pill
    /// rather than collapsing to the width of their own text.
    static let verticalHoveredPillMinWidth: CGFloat = 72

    /// Widest it may grow, so a long workspace name truncates instead of running
    /// most of the way across the panes.
    static let verticalHoveredPillMaxWidth: CGFloat =
        verticalWidth + verticalHoverOverhang - verticalPadding

    /// Horizontal padding inside the expanded pill, either side of its contents.
    static let verticalHoveredPillPadding: CGFloat = 12

    /// Gap between the close button and the pill's trailing edge. Tighter than
    /// the text padding: the button's own hover circle supplies the visual air.
    static let verticalHoveredPillCloseInset: CGFloat = 5

    /// Trailing column the close button claims: inset, button, and a gap before
    /// the name. Mirrors the toolbar pill so both bars read the same.
    static let verticalHoveredPillCloseSlot: CGFloat =
        WorkspacePillStyle.closeButtonSize + verticalHoveredPillCloseInset + 5

    /// Font the expanded pill's name is drawn in. Shared by the measure and the draw
    /// so the pill can't be sized against different metrics than it paints with.
    static func verticalHoveredPillFont(selected: Bool) -> NSFont {
        selected ? pillLabelSelected : pillLabelRegular
    }

    /// Frame of the expanded pill for the hovered workspace: same top and height as
    /// its resting pill, grown inward over the panes. Width hugs the name — clamped
    /// to a minimum so short names still look like pills, and to a maximum so long
    /// ones truncate rather than sprawl.
    func verticalHoveredPillRect(at index: Int) -> CGRect {
        let rest = verticalItemRect(at: index)
        guard index >= 0, index < items.count else { return rest }
        let item = items[index]

        // Measured once per name, not per call: this runs from `hitTest`, which
        // fires for every mouse event over the strip *and* its overhang band.
        let selected = index == selectedIndex
        let cacheKey = "\(selected)|\(item.name)"
        let textW: CGFloat
        if let cached = nameWidthCache[cacheKey] {
            textW = cached
        } else {
            let font = Self.verticalHoveredPillFont(selected: selected)
            textW = (item.name as NSString).size(withAttributes: [.font: font]).width
            nameWidthCache[cacheKey] = textW
        }
        // Padding either side, plus room for the close button (pinned items show a
        // pin inside the pill instead, which needs no reserved column).
        let trailing =
            item.isPinned ? Self.verticalHoveredPillPadding : Self.verticalHoveredPillCloseSlot
        let w = min(
            Self.verticalHoveredPillMaxWidth,
            max(
                Self.verticalHoveredPillMinWidth,
                ceil(textW) + Self.verticalHoveredPillPadding + trailing))

        // Grows toward the panes: rightward on a left bar, leftward on a right bar,
        // so it never runs off the window edge.
        let x = isRightAligned ? rest.maxX - w : rest.minX
        return CGRect(x: x, y: rest.minY, width: w, height: rest.height)
    }

    /// Height of one pill in the vertical strip.
    static let verticalItemSize: CGFloat = 36

    /// Gap between stacked pills.
    static let verticalItemGap: CGFloat = 6

    /// Depth of the scroll fade at each end of the pill stack. Deep enough that a
    /// clipped pill has fully dissolved before it reaches the edge, matching the
    /// top bar's left/right fades.
    static let verticalFadeHeight: CGFloat = 24

    /// Fonts used per pill on every draw pass — built once rather than per pill.
    // Same weights as the top bar's pills (`ToolbarView.Fonts.ws11*`).
    nonisolated(unsafe) static let pillLabelSelected = NSFont.systemFont(
        ofSize: 13, weight: .semibold)
    nonisolated(unsafe) static let pillLabelRegular = NSFont.systemFont(
        ofSize: 13, weight: .medium)

    /// How far the vertical strip is scrolled, in points. The mirror of the top
    /// bar's `workspaceScrollOffset`, only along Y.
    var verticalScrollOffset: CGFloat = 0 {
        didSet {
            if verticalScrollOffset != oldValue { needsDisplay = true }
        }
    }

    /// Total height of the pill stack, before clamping. The `+` is pinned to the
    /// bottom of the strip rather than riding at the end of the stack, so it is not
    /// counted here.
    private(set) var verticalContentHeight: CGFloat = 0

    /// Height the scrolling pill stack gets: the strip minus the band reserved for
    /// the pinned `+`, so pills scroll *behind* it instead of off the bottom.
    var verticalScrollViewportHeight: CGFloat {
        max(0, bounds.height - Self.verticalItemSize - Self.verticalItemGap)
    }

    /// Furthest the strip can scroll: zero when everything already fits.
    var maxVerticalScrollOffset: CGFloat {
        max(0, verticalContentHeight - verticalScrollViewportHeight)
    }

    /// Frame of the pill at `index`, in view coordinates, with the scroll offset
    /// applied. The single source every draw and hit-test path walks, so the drawn
    /// pill and its click target can't drift apart.
    func verticalItemRect(at index: Int) -> CGRect {
        let top = index >= 0 && index < rowTops.count ? rowTops[index] : verticalContentHeight
        let y = top - verticalScrollOffset
        return CGRect(
            x: verticalPillX, y: y, width: verticalPillWidth, height: Self.verticalItemSize)
    }

    /// Frame of the `+`, pinned to the bottom of the strip. It used to ride at the
    /// end of the stack, which scrolled it out of reach once the workspaces
    /// overflowed. Same footprint as a pill.
    var verticalPlusRect: CGRect {
        CGRect(
            x: verticalPillX, y: bounds.height - Self.verticalItemSize,
            width: verticalPillWidth, height: Self.verticalItemSize)
    }

    /// Only the visible strip — and the expanded hover pill — take mouse events. The
    /// rest of the frame is transparent scratch space lying over the panes, so it
    /// must let clicks through or it would swallow half a terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isVertical else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let strip = CGRect(
            x: verticalStripX, y: 0, width: Self.verticalWidth, height: bounds.height)
        if strip.contains(local) { return self }
        if hoveredIndex >= 0, hoveredIndex < items.count,
            verticalHoveredPillRect(at: hoveredIndex).contains(local)
        {
            return self
        }
        return nil
    }

    /// Test seam for `clampVerticalScroll` / `verticalCloseButtonRect`, which are
    /// private because nothing in the app calls them from outside.
    func clampVerticalScrollForTesting() { clampVerticalScroll() }
    func verticalCloseButtonRectForTesting(in pillRect: CGRect) -> CGRect {
        verticalCloseButtonRect(in: pillRect)
    }

    func clampVerticalScroll() {
        verticalScrollOffset = min(max(0, verticalScrollOffset), maxVerticalScrollOffset)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if isVertical {
            return NSSize(width: Self.verticalFrameWidth, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    /// Measured expanded-pill name widths, keyed by "selected|name". Cleared when
    /// the items change; fonts are static so nothing else invalidates it.
    private var nameWidthCache: [String: CGFloat] = [:]

    func setItems(_ items: [Item], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        nameWidthCache.removeAll(keepingCapacity: true)
        rebuildLayout()
        if hoveredIndex >= 0, hiddenRows.contains(hoveredIndex) { hoveredIndex = -1 }
        clampVerticalScroll()
        scrollToSelectedVertical()
        needsDisplay = true
    }

    /// Lay out pills and group headers top to bottom. Each group sits in a tray
    /// padded `WorkspacePillStyle.groupTrayPadding` around its header and visible members. A collapsed
    /// group still shows its selected member, so the active workspace never disappears.
    private func rebuildLayout() {
        let step = Self.verticalItemSize + Self.verticalItemGap
        var tops: [CGFloat] = []
        tops.reserveCapacity(items.count)
        var hidden: Set<Int> = []
        var headers: [GroupHeader] = []
        var y: CGFloat = 0
        var i = 0
        while i < items.count {
            guard let gid = items[i].groupID else {
                tops.append(y)
                y += step
                i += 1
                continue
            }
            var end = i
            while end < items.count, items[end].groupID == gid { end += 1 }
            let collapsed = items[i].groupCollapsed
            let height = collapsed ? Self.verticalItemSize : Self.groupHeaderHeight
            let hiddenActivity = collapsed && (i..<end).contains { $0 != selectedIndex && items[$0].hasActivity }
            let pad = WorkspacePillStyle.groupTrayPadding
            y += pad
            let headerTop = y
            y += height + Self.verticalItemGap
            for k in i..<end {
                tops.append(y)
                if collapsed && k != selectedIndex {
                    hidden.insert(k)
                } else {
                    y += step
                }
            }
            y += pad
            let trayHeight = y - Self.verticalItemGap - (headerTop - pad)
            headers.append(
                GroupHeader(
                    id: gid, name: items[i].groupName ?? "", collapsed: collapsed, members: i..<end,
                    top: headerTop, height: height, trayHeight: trayHeight,
                    hiddenActivity: hiddenActivity, color: items[i].groupColor))
            i = end
        }
        rowTops = tops
        hiddenRows = hidden
        groupHeaders = headers
        verticalContentHeight = y
    }

    // MARK: - Testing Hooks

    /// Directly invoke the double-click edit path. For tests only.
    func triggerDoubleClickForTesting(at index: Int) {
        editWorkspace(at: index)
    }

    /// Directly invoke the single-click select/close path. For tests only.
    func triggerSingleClickForTesting(at index: Int) {
        guard index >= 0, index < items.count else { return }
        handleVerticalClick(
            CGPoint(x: verticalItemRect(at: index).midX, y: verticalItemRect(at: index).midY))
    }

}

// MARK: - Accessibility

extension WorkspaceBarView {
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Workspaces" }

    override func accessibilityChildren() -> [Any]? {
        var elements: [Any] = []
        for header in groupHeaders {
            let state = header.collapsed ? "collapsed" : "expanded"
            let id = header.id
            elements.append(
                AccessibleElement(
                    parent: self, role: .button, label: "Group \(header.name), \(state)",
                    localRect: groupHeaderRect(header)
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.workspaceBar(self, toggleGroup: id)
                })
        }
        for (index, item) in items.enumerated() where !hiddenRows.contains(index) {
            let label = item.isPinned ? "Workspace \(item.name), pinned" : "Workspace \(item.name)"
            elements.append(
                AccessibleElement(
                    parent: self, role: .radioButton, label: label, localRect: verticalItemRect(at: index),
                    selected: index == selectedIndex
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.workspaceBar(self, didSelectAt: index)
                })
        }
        elements.append(
            AccessibleElement(parent: self, role: .button, label: "New workspace", localRect: verticalPlusRect) {
                [weak self] in
                guard let self else { return }
                self.delegate?.workspaceBarDidRequestNewWorkspace(self)
            })
        return elements + (super.accessibilityChildren() ?? [])
    }
}
