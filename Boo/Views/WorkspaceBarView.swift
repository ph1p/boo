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
    private var dragSourceIndex: Int?
    private var dropTargetIndex: Int?
    /// Pill the drag would stack onto (forming or joining its group).
    private var dropStackIndex: Int?
    /// Group header the drag would join.
    private var dropGroupID: String?
    /// Group whose header is being dragged (the whole group moves).
    private var draggedGroupID: String?

    // Ghost drag state
    private var ghostWindow: DragGhostWindow?
    private var isDragging: Bool = false

    // Hover state
    var hoveredIndex: Int = -1
    /// Group whose header (or collapsed folder) is under the cursor.
    private(set) var hoveredGroupID: String?
    private var isPlusButtonHovered: Bool = false
    /// Pointer is over the expanded pill's close button (draws its hover circle).
    private var isCloseButtonHovered: Bool = false
    private var wsBarTrackingArea: NSTrackingArea?

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
    static let verticalHoveredPillMinWidth: CGFloat = 110

    /// Widest it may grow, so a long workspace name truncates instead of running
    /// most of the way across the panes.
    static let verticalHoveredPillMaxWidth: CGFloat =
        verticalWidth + verticalHoverOverhang - verticalPadding

    /// Horizontal padding inside the expanded pill, either side of its contents.
    static let verticalHoveredPillPadding: CGFloat = 12

    /// Font the expanded pill's name is drawn in. Shared by the measure and the draw
    /// so the pill can't be sized against different metrics than it paints with.
    static func verticalHoveredPillFont(selected: Bool) -> NSFont {
        NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .regular)
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
            item.isPinned ? 0 : WorkspacePillStyle.closeButtonSize + Self.verticalHoveredPillPadding
        let w = min(
            Self.verticalHoveredPillMaxWidth,
            max(
                Self.verticalHoveredPillMinWidth,
                ceil(textW) + Self.verticalHoveredPillPadding * 2 + trailing))

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
    nonisolated(unsafe) static let plusGlyphFont = NSFont.systemFont(ofSize: 18, weight: .light)
    nonisolated(unsafe) static let pillLabelSelected = NSFont.systemFont(
        ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let pillLabelRegular = NSFont.systemFont(
        ofSize: 12, weight: .regular)

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

    private func clampVerticalScroll() {
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

    /// Frame of a group header in view coordinates (scroll applied).
    func groupHeaderRect(_ header: GroupHeader) -> CGRect {
        CGRect(
            x: verticalPillX, y: header.top - verticalScrollOffset, width: verticalPillWidth,
            height: header.height)
    }

    /// Frame of a group's tray in view coordinates (scroll applied).
    func groupTrayRect(_ header: GroupHeader) -> CGRect {
        let pad = WorkspacePillStyle.groupTrayPadding
        return CGRect(
            x: verticalPillX - pad, y: header.top - pad - verticalScrollOffset,
            width: verticalPillWidth + pad * 2, height: header.trayHeight)
    }

    private func hitTestGroupHeader(at point: NSPoint) -> GroupHeader? {
        if verticalPlusRect.contains(point) || point.y > verticalScrollViewportHeight { return nil }
        for header in groupHeaders {
            let r = groupHeaderRect(header)
            let strip = CGRect(x: verticalStripX, y: r.minY, width: Self.verticalWidth, height: r.height)
            if strip.contains(point) { return header }
        }
        return nil
    }

    /// Trays plus header rows (or collapsed folders), drawn under the pills.
    private func drawGroupHeaders(_ ctx: CGContext, theme: TerminalTheme) {
        for header in groupHeaders {
            let tray = groupTrayRect(header)
            if tray.maxY < 0 || tray.minY > verticalScrollViewportHeight { continue }
            let rect = groupHeaderRect(header)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            if isDragging && draggedGroupID == header.id { ctx.setAlpha(0.3) }
            let highlighted =
                dropGroupID == header.id || dropStackIndex.map { header.members.contains($0) } == true
            WorkspacePillStyle.drawGroupTray(
                ctx, rect: tray, color: header.color, highlighted: highlighted, theme: theme)
            let hovered = hoveredGroupID == header.id
            let tint = WorkspacePillStyle.groupTint(color: header.color, hovered: hovered, theme: theme)
            if header.collapsed {
                drawCollapsedGroup(ctx, header, in: rect, tint: tint, hovered: hovered, theme: theme)
            } else {
                drawGroupHeaderRow(ctx, header, in: rect, tint: tint, hovered: hovered, theme: theme)
            }
        }
    }

    /// Expanded group: chevron plus the first letters of the name, centred in the row.
    private func drawGroupHeaderRow(
        _ ctx: CGContext, _ header: GroupHeader, in rect: CGRect, tint: NSColor, hovered: Bool,
        theme: TerminalTheme
    ) {
        if hovered {
            WorkspacePillStyle.fillGroupHeaderHover(ctx, rect: rect, radius: rect.height / 2, theme: theme)
        }
        let chevron: CGFloat = 7
        let gap: CGFloat = 3
        let label = String(header.name.prefix(3)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.groupLabelFont, .foregroundColor: tint]
        let size = label.size(withAttributes: attrs)
        let textW = min(size.width, rect.width - chevron - gap - 4)
        let x = rect.midX - (chevron + gap + textW) / 2
        WorkspacePillStyle.drawGroupChevron(
            collapsed: false, in: CGRect(x: x, y: rect.midY - chevron / 2, width: chevron, height: chevron),
            color: tint)
        label.draw(
            in: CGRect(x: x + chevron + gap, y: rect.midY - size.height / 2, width: textW, height: size.height),
            withAttributes: attrs)
    }

    /// Collapsed group: a folder pill with the group's initials and a member-count badge.
    private func drawCollapsedGroup(
        _ ctx: CGContext, _ header: GroupHeader, in rect: CGRect, tint: NSColor, hovered: Bool,
        theme: TerminalTheme
    ) {
        WorkspacePillStyle.fill(
            ctx, rect: rect, active: false, hovered: hovered, wsColor: header.color, neutral: theme.chromeMuted)
        let label = String(header.name.prefix(2)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.pillLabelRegular, .foregroundColor: tint]
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 3), withAttributes: attrs)

        WorkspacePillStyle.drawGroupCountBadge(
            ctx, count: header.members.count, center: CGPoint(x: rect.midX, y: rect.maxY - 9), height: 12,
            font: Self.groupCountFont, hiddenActivity: header.hiddenActivity, theme: theme, tint: header.color)
        WorkspacePillStyle.drawStatus(
            ctx, rect: rect, hasActivity: header.hiddenActivity, progress: nil, theme: theme, inset: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        // This view is only ever used as a vertical (left/right) bar; the top bar
        // is drawn by ToolbarView. Click/hit-test still support the horizontal
        // layout for tests, but there is no horizontal draw path.
        guard isVertical, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawVertical(ctx)
    }

    // MARK: - Vertical Drawing (left bar)

    private func drawVertical(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme

        // No fill and no edge stroke: like the toolbar and status bar, this is a
        // bare strip over the window backdrop. Only the pills carry chrome.

        // Resolved once, not per pill: `IslandMetrics.borderColor` re-reads the
        // theme and re-runs the chrome-border blend on every access.
        let islandBorder = IslandMetrics.borderColor

        // Clip the scrolling stack to its viewport so a pill straddling the bottom
        // edge is cut off cleanly instead of bleeding into the pinned `+`.
        ctx.saveGState()
        ctx.clip(
            to: CGRect(x: 0, y: 0, width: bounds.width, height: verticalScrollViewportHeight))

        drawGroupHeaders(ctx, theme: theme)

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            // The hovered workspace is painted separately, expanded, after this loop
            // so it floats above its neighbours instead of being overdrawn by them.
            if i == hoveredIndex || hiddenRows.contains(i) { continue }
            let wsColor = item.resolvedColor

            let pillRect = verticalItemRect(at: i)
            // Skip pills scrolled out of the stack's viewport — nothing to paint, and
            // it keeps the cost flat as the workspace count grows.
            if pillRect.maxY < 0 || pillRect.minY > verticalScrollViewportHeight { continue }

            // The dragged pill stays as a faint placeholder; the ghost carries it.
            let isLifted =
                isDragging && (dragSourceIndex == i || (item.groupID != nil && item.groupID == draggedGroupID))
            if isLifted {
                ctx.saveGState()
                ctx.setAlpha(0.3)
            }
            defer { if isLifted { ctx.restoreGState() } }

            // Identical fill + accent border as the top bar, via the shared
            // WorkspacePillStyle. Only the square geometry differs here.
            WorkspacePillStyle.fill(
                ctx, rect: pillRect, active: isSelected, hovered: false,
                wsColor: wsColor, neutral: theme.chromeMuted)
            if isSelected {
                WorkspacePillStyle.strokeBorder(ctx, rect: pillRect, theme: theme, color: wsColor)
            } else {
                // Every pill is an island, so every pill carries the island hairline —
                // tinted by the workspace's own colour when it has one.
                WorkspacePillStyle.strokeIslandBorder(
                    ctx, rect: pillRect, wsColor: wsColor, neutral: islandBorder)
            }

            // Draw first character(s) as label. Same text-color model as the top bar.
            let label = String(item.name.prefix(2)).uppercased()
            let textColor = WorkspacePillStyle.labelColor(
                wsColor: wsColor, active: isSelected, text: theme.chromeText,
                muted: theme.chromeMuted)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isSelected ? Self.pillLabelSelected : Self.pillLabelRegular,
                .foregroundColor: textColor
            ]
            let labelSize = (label as NSString).size(withAttributes: attrs)
            let labelX = pillRect.midX - labelSize.width / 2
            let labelY = pillRect.midY - labelSize.height / 2
            (label as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)

            // Pin icon for pinned items
            if item.isPinned {
                drawPinIcon(ctx, at: NSPoint(x: pillRect.minX + 2, y: pillRect.minY + 2), color: textColor)
            }
            WorkspacePillStyle.drawStatus(
                ctx, rect: pillRect, hasActivity: item.hasActivity, progress: item.progress, theme: theme,
                inset: 4)
        }

        ctx.restoreGState()

        // Scroll fades, mirroring the top bar's left/right edges along Y: a pill
        // clipped at the viewport boundary dissolves into the backdrop instead of
        // ending on a hard cut.
        if verticalScrollOffset > 0 {
            drawVerticalFadeEdge(ctx, at: 0, height: Self.verticalFadeHeight, topDown: true)
        }
        if verticalScrollOffset < maxVerticalScrollOffset {
            drawVerticalFadeEdge(
                ctx, at: verticalScrollViewportHeight - Self.verticalFadeHeight,
                height: Self.verticalFadeHeight, topDown: false)
        }

        // The hovered workspace, expanded over the panes: full name plus the close
        // button, neither of which fits in the two-letter resting pill. Outside the
        // stack's clip — it deliberately floats past the strip.
        drawExpandedHoverPill(ctx, theme: theme, islandBorder: islandBorder)

        // Plus button — pinned to the bottom, painted last so a pill scrolled to the
        // very end passes behind it.
        drawPlusButton(ctx, in: verticalPlusRect, theme: theme)

        // Draw drop insertion indicator
        if let dropIdx = dropTargetIndex {
            // At a group's first member the line sits above the group's tray.
            let header = groupHeaders.first { $0.members.lowerBound == dropIdx }
            let indicatorY = (header.map { groupTrayRect($0).minY } ?? verticalItemRect(at: dropIdx).minY) - 3
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: verticalPillX, y: indicatorY, width: verticalPillWidth, height: 2))
        }
        drawStackHighlight(ctx, theme: theme)
    }

    /// Accent ring around an ungrouped stack-target pill. A grouped target, or a
    /// group header the drop would join, highlights its whole tray instead.
    private func drawStackHighlight(_ ctx: CGContext, theme: TerminalTheme) {
        guard let idx = dropStackIndex, items.indices.contains(idx), items[idx].groupID == nil else { return }
        WorkspacePillStyle.strokeDropRing(ctx, around: verticalItemRect(at: idx), theme: theme)
    }

    /// Dissolve the clipped end of the pill stack into the window backdrop, the
    /// vertical twin of `ToolbarView.drawFadeEdge`. `topDown` means opaque at `y`
    /// fading away downward — the view is flipped, so that is the *top* edge.
    ///
    /// Only the visible strip is faded: the frame's overhang is transparent scratch
    /// space over the panes, and painting backdrop into it would show as a band.
    private func drawVerticalFadeEdge(
        _ ctx: CGContext, at y: CGFloat, height: CGFloat, topDown: Bool
    ) {
        WorkspacePillStyle.drawBackdropFade(
            ctx,
            in: CGRect(x: verticalStripX, y: y, width: Self.verticalWidth, height: height),
            from: CGPoint(x: 0, y: topDown ? y : y + height),
            to: CGPoint(x: 0, y: topDown ? y + height : y))
    }

    /// Paint the hovered workspace as a wide pill floating over the panes. Drawn
    /// after the resting stack so it sits on top of its neighbours, with a shadow to
    /// read as a layer above the content rather than a hole punched in the strip.
    private func drawExpandedHoverPill(
        _ ctx: CGContext, theme: TerminalTheme, islandBorder: NSColor
    ) {
        guard hoveredIndex >= 0, hoveredIndex < items.count else { return }
        let i = hoveredIndex
        let item = items[i]
        let rest = verticalItemRect(at: i)
        // A pill scrolled out of the stack has no business floating over the panes.
        if rest.maxY < 0 || rest.minY > verticalScrollViewportHeight { return }

        let rect = verticalHoveredPillRect(at: i)
        let isSelected = i == selectedIndex
        let wsColor = item.resolvedColor

        // Opaque backdrop under the pill fill: the fill itself is translucent, and
        // terminal text showing through a floating control reads as a glitch.
        ctx.setFillColor(theme.chromeBg.cgColor)
        WorkspacePillStyle.fillRoundedRect(ctx, rect: rect)

        WorkspacePillStyle.fill(
            ctx, rect: rect, active: isSelected, hovered: true, wsColor: wsColor,
            neutral: theme.chromeMuted)
        // A hairline all the way round: with the shadow gone this is what separates
        // the floating pill from the terminal content behind it. The active
        // workspace keeps its accent stroke instead.
        if isSelected {
            WorkspacePillStyle.strokeBorder(ctx, rect: rect, theme: theme, color: wsColor)
        } else {
            WorkspacePillStyle.strokeIslandBorder(
                ctx, rect: rect, wsColor: wsColor, neutral: islandBorder)
        }

        // `chromeText` as `muted` too: the expanded pill's un-selected fallback is
        // full-strength text, unlike the resting pills' muted two-letter label.
        let textColor = WorkspacePillStyle.labelColor(
            wsColor: wsColor, active: isSelected, text: theme.chromeText,
            muted: theme.chromeText)

        let closeSize = WorkspacePillStyle.closeButtonSize
        let sidePad = Self.verticalHoveredPillPadding
        // Text runs from the strip side toward the panes, stopping short of the close
        // button so a long workspace name truncates instead of colliding with it.
        let textInset = item.isPinned ? sidePad : sidePad + closeSize
        let textX = isRightAligned ? rect.minX + textInset : rect.minX + sidePad
        let textW = rect.width - sidePad - textInset

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.verticalHoveredPillFont(selected: isSelected),
            .foregroundColor: textColor,
            .paragraphStyle: para
        ]
        let name = item.name as NSString
        let textH = name.size(withAttributes: attrs).height
        name.draw(
            in: CGRect(x: textX, y: rect.midY - textH / 2, width: max(0, textW), height: textH),
            withAttributes: attrs)

        if item.isPinned {
            drawPinIcon(
                ctx, at: NSPoint(x: rect.minX + 3, y: rect.minY + 3), color: textColor)
        } else {
            WorkspacePillStyle.drawCloseButton(
                ctx, in: verticalCloseButtonRect(in: rect),
                tint: wsColor ?? theme.chromeMuted, hovered: isCloseButtonHovered)
        }
        // The close button owns its slot on hover, so the dot only shows on pinned pills.
        WorkspacePillStyle.drawStatus(
            ctx, rect: rect, hasActivity: item.hasActivity && item.isPinned, progress: item.progress,
            theme: theme)
    }

    // MARK: - Pin Icon

    private func drawPinIcon(_ ctx: CGContext, at origin: NSPoint, color: NSColor) {
        let iconSize: CGFloat = 7
        let iconRect = NSRect(x: origin.x, y: origin.y, width: iconSize, height: iconSize)
        if let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
            let sized = pinImage.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? pinImage
            sized.isTemplate = true
            let tintColor = color.withAlphaComponent(0.5)

            let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                tintColor.set()
                sized.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSRect(origin: .zero, size: drawRect.size).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        } else {
            ctx.setFillColor(color.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: origin.x + 1, y: origin.y + 1, width: 5, height: 5))
        }
    }

    // MARK: - Plus Button

    /// Hover close-button rect for a vertical pill: top corner away from the bar's
    /// edge — upper-right on the left bar, upper-left on the right bar. (Flipped view,
    /// so the top is `minY`.)
    private func verticalCloseButtonRect(in pillRect: CGRect) -> CGRect {
        let circleSize = WorkspacePillStyle.closeButtonSize
        // Lives inside the *expanded* hover pill, at the end facing the panes. The
        // resting pill is only as wide as its two-letter label, so there is nowhere
        // to put it there without covering the text.
        let inset = Self.verticalHoveredPillPadding
        let circleX =
            isRightAligned ? pillRect.minX + inset : pillRect.maxX - circleSize - inset
        return CGRect(
            x: circleX, y: pillRect.midY - circleSize / 2, width: circleSize, height: circleSize)
    }

    private func drawPlusButton(_ ctx: CGContext, in rect: CGRect, theme: TerminalTheme) {
        if isPlusButtonHovered {
            ctx.setFillColor(theme.hoverFill.cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: rect)
        }

        let plusColor =
            isPlusButtonHovered
            ? theme.textSecondary
            : theme.textTertiary
        let attrs: [NSAttributedString.Key: Any] = [
            // The `+` sits in a full pill-sized footprint, so it carries a heavier
            // glyph than a plain toolbar button would.
            .font: Self.plusGlyphFont,
            .foregroundColor: plusColor
        ]
        let str = "+" as NSString
        let strSize = str.size(withAttributes: attrs)
        str.draw(
            at: NSPoint(x: rect.midX - strSize.width / 2, y: rect.midY - strSize.height / 2),
            withAttributes: attrs)
    }

    // MARK: - Click Handling

    override func mouseDown(with event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        if let header = hitTestGroupHeader(at: startPoint) {
            handleGroupHeaderMouseDown(startPoint: startPoint, header: header)
            return
        }
        let hitIdx = hitTestItemIndex(at: startPoint)

        // If click is not on any item, check for plus button or start a window drag
        guard let idx = hitIdx, idx >= 0, idx < items.count else {
            if isPlusButtonHit(at: startPoint) {
                delegate?.workspaceBarDidRequestNewWorkspace(self)
            } else {
                window?.performDrag(with: event)
            }
            return
        }

        // Double-click opens the inline editor
        if event.clickCount == 2 {
            editWorkspace(at: idx)
            return
        }

        // Run a local tracking loop to prevent isMovableByWindowBackground
        // from hijacking the drag. We own the entire mouse sequence here.
        var didStartDrag = false

        guard let eventWindow = window else { return }
        while true {
            guard let nextEvent = eventWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            if nextEvent.type == .leftMouseUp {
                if !didStartDrag {
                    // Plain click — select or close
                    handleVerticalClick(startPoint)
                } else if let point = Self.screenPointOutsideWindow(nextEvent), let src = dragSourceIndex {
                    delegate?.workspaceBar(self, dropWorkspaceAt: src, atScreenPoint: point)
                } else {
                    executeDrop()
                }
                break
            }

            // leftMouseDragged
            if !didStartDrag {
                let dragPoint = convert(nextEvent.locationInWindow, from: nil)
                let distance = hypot(dragPoint.x - startPoint.x, dragPoint.y - startPoint.y)
                guard distance > 3 else { continue }
                // A lone workspace still drags: it can move into another window.
                guard !items[idx].isPinned else { break }

                dragSourceIndex = idx
                isDragging = true
                didStartDrag = true
                createGhostWindow(for: idx, event: nextEvent)
            }

            handleDragMove(nextEvent)
            delegate?.workspaceBar(self, workspaceDragMovedOutsideTo: Self.screenPointOutsideWindow(nextEvent))
        }

        if didStartDrag {
            delegate?.workspaceBar(self, workspaceDragMovedOutsideTo: nil)
            cleanupDrag()
        }
    }

    // MARK: - Group Drag

    /// Click on a header toggles the group; dragging it moves the whole group
    /// within the strip or, released outside the window, into another window.
    private func handleGroupHeaderMouseDown(startPoint: NSPoint, header: GroupHeader) {
        guard let eventWindow = window else { return }
        var didStartDrag = false
        while true {
            guard let next = eventWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp {
                if !didStartDrag {
                    delegate?.workspaceBar(self, toggleGroup: header.id)
                } else if let point = Self.screenPointOutsideWindow(next) {
                    delegate?.workspaceBar(self, dropGroup: header.id, atScreenPoint: point)
                } else if let dest = dropTargetIndex {
                    delegate?.workspaceBar(self, moveGroup: header.id, to: dest)
                }
                break
            }
            let point = convert(next.locationInWindow, from: nil)
            if !didStartDrag {
                guard hypot(point.x - startPoint.x, point.y - startPoint.y) > 3 else { continue }
                didStartDrag = true
                isDragging = true
                draggedGroupID = header.id
                createGroupGhostWindow(for: header, event: next)
            }
            ghostWindow?.move(toCenter: DragGhostWindow.screenPoint(of: next))
            let outside = Self.screenPointOutsideWindow(next)
            let dest =
                outside != nil
                ? nil
                : WorkspaceGroupDrop.insertionIndex(
                    raw: groupDragRawIndex(contentY: point.y + verticalScrollOffset), moving: header.members,
                    groups: groupHeaders.map(\.members),
                    firstUnpinned: items.firstIndex { !$0.isPinned } ?? items.count)
            setDropTarget(insert: dest, stack: nil, group: nil)
            delegate?.workspaceBar(self, workspaceDragMovedOutsideTo: outside)
        }
        if didStartDrag {
            delegate?.workspaceBar(self, workspaceDragMovedOutsideTo: nil)
            draggedGroupID = nil
            cleanupDrag()
        }
    }

    /// Insertion index for a group drag: before the first visible pill or group
    /// header whose midpoint lies below `contentY`.
    private func groupDragRawIndex(contentY: CGFloat) -> Int {
        let size = Self.verticalItemSize
        var raw = items.count
        for i in items.indices where !hiddenRows.contains(i) && contentY < rowTops[i] + size / 2 {
            raw = i
            break
        }
        for header in groupHeaders where contentY < header.top + header.height / 2 {
            raw = min(raw, header.members.lowerBound)
            break
        }
        return raw
    }

    private func createGroupGhostWindow(for header: GroupHeader, event: NSEvent) {
        guard let window else { return }
        let rect = groupHeaderRect(header)
        let size = CGSize(width: rect.width, height: max(rect.height, Self.verticalItemSize))
        let ghost = WorkspaceDragGhostView(
            size: size, label: String(header.name.prefix(2)).uppercased(), font: Self.pillLabelRegular,
            centered: true, wsColor: header.color, active: false)
        let frame = CGRect(origin: rect.origin, size: size)
        ghostWindow = DragGhostWindow(
            content: ghost, sourceFrame: window.convertToScreen(convert(frame, to: nil)),
            cursor: DragGhostWindow.screenPoint(of: event), alpha: 0.95)
        hoveredIndex = -1
        needsDisplay = true
    }

    // MARK: - Ghost Drag System

    private func createGhostWindow(for index: Int, event: NSEvent) {
        guard let window else { return }
        let item = items[index]
        let rect = verticalItemRect(at: index)
        let active = index == selectedIndex
        let ghost = WorkspaceDragGhostView(
            size: rect.size, label: String(item.name.prefix(2)).uppercased(),
            font: active ? Self.pillLabelSelected : Self.pillLabelRegular, centered: true,
            wsColor: item.resolvedColor, active: active)
        ghostWindow = DragGhostWindow(
            content: ghost, sourceFrame: window.convertToScreen(convert(rect, to: nil)),
            cursor: DragGhostWindow.screenPoint(of: event), alpha: 0.95)
        // The expanded hover pill would cover the faded placeholder.
        hoveredIndex = -1
        needsDisplay = true
    }

    private func handleDragMove(_ event: NSEvent) {
        ghostWindow?.move(toCenter: DragGhostWindow.screenPoint(of: event))

        // Update drop target
        updateDropTarget(event)
    }

    /// Screen location of `event` when it lies outside the event's window.
    static func screenPointOutsideWindow(_ event: NSEvent) -> NSPoint? {
        guard let window = event.window else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return window.frame.contains(point) ? nil : point
    }

    private func updateDropTarget(_ event: NSEvent) {
        if Self.screenPointOutsideWindow(event) != nil {
            setDropTarget(insert: nil, stack: nil, group: nil)
            return
        }
        guard let eventWindow = event.window ?? self.window else { return }
        let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        guard let myWindow = self.window else { return }
        let windowPoint = myWindow.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)

        guard let src = dragSourceIndex else { return }
        let srcGroup = items[src].groupID

        // Onto a group header: join that group.
        if let header = hitTestGroupHeader(at: point) {
            setDropTarget(insert: nil, stack: nil, group: header.id == srcGroup ? nil : header.id)
            return
        }

        // Point is in view space, so undo the scroll before mapping to an index.
        let contentY = point.y + verticalScrollOffset
        let size = Self.verticalItemSize

        // Middle half of another pill: stack onto it.
        for i in items.indices where i != src && !hiddenRows.contains(i) {
            let top = rowTops[i]
            guard contentY >= top + size / 4 && contentY < top + size * 3 / 4 else { continue }
            let target = items[i]
            let sameGroup = target.groupID != nil && target.groupID == srcGroup
            if !target.isPinned && !sameGroup {
                setDropTarget(insert: nil, stack: i, group: nil)
                return
            }
            break
        }

        // Otherwise reorder: before the first visible pill whose midpoint lies below the cursor.
        var rawIdx = items.count
        for i in items.indices where !hiddenRows.contains(i) {
            if contentY < rowTops[i] + size / 2 {
                rawIdx = i
                break
            }
        }
        setDropTarget(insert: validDropIndex(raw: rawIdx), stack: nil, group: nil)
    }

    private func setDropTarget(insert: Int?, stack: Int?, group: String?) {
        guard insert != dropTargetIndex || stack != dropStackIndex || group != dropGroupID else { return }
        dropTargetIndex = insert
        dropStackIndex = stack
        dropGroupID = group
        needsDisplay = true
    }

    private func validDropIndex(raw: Int) -> Int? {
        guard let src = dragSourceIndex else { return nil }
        // No-op moves
        if raw == src || raw == src + 1 { return nil }
        let lo = min(src, raw)
        let hi = max(src, raw)
        for i in lo..<hi where i != src {
            if items[i].isPinned { return nil }
        }
        return raw
    }

    private func executeDrop() {
        guard let sourceIdx = dragSourceIndex else { return }
        if let gid = dropGroupID {
            delegate?.workspaceBar(self, moveWorkspaceAt: sourceIdx, intoGroup: gid)
        } else if let target = dropStackIndex {
            delegate?.workspaceBar(self, stackWorkspaceAt: sourceIdx, onto: target)
        } else if let dropIdx = dropTargetIndex {
            delegate?.workspaceBar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
        }
    }

    private func cleanupDrag() {
        ghostWindow?.fadeOut()
        ghostWindow = nil
        isDragging = false
        dragSourceIndex = nil
        dropTargetIndex = nil
        dropStackIndex = nil
        dropGroupID = nil
        needsDisplay = true
    }

    /// Returns screen-space rects for each workspace pill, used for tab-drag hover detection.
    func workspacePillScreenFrames() -> [(index: Int, screenFrame: NSRect)] {
        guard let window = window else { return [] }
        var result: [(Int, NSRect)] = []
        for (i, _) in items.enumerated() where !hiddenRows.contains(i) {
            let windowRect = convert(verticalItemRect(at: i), to: nil)
            result.append((i, window.convertToScreen(windowRect)))
        }
        return result
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let header = hitTestGroupHeader(at: point) {
            let entries = delegate?.workspaceBar(self, menuItemsForGroup: header.id) ?? []
            guard !entries.isEmpty else { return }
            let menu = NSMenu()
            entries.forEach(menu.addItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let idx = hitTestItemIndex(at: point), idx >= 0, idx < items.count else { return }
        showContextMenu(at: idx, event: event)
    }

    private func showContextMenu(at index: Int, event: NSEvent) {
        let menu = NSMenu()
        let item = items[index]

        let editItem = NSMenuItem(
            title: "Edit Workspace…", action: #selector(contextEditWorkspace(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.tag = index
        menu.addItem(editItem)

        let pinTitle = item.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextTogglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.tag = index
        menu.addItem(pinItem)

        menu.addItem(.separator())

        if !item.isPinned && items.count > 1 {
            let moveItem = NSMenuItem(
                title: "Move to New Window", action: #selector(contextMoveToNewWindow(_:)), keyEquivalent: "")
            moveItem.target = self
            moveItem.tag = index
            menu.addItem(moveItem)
        }
        let extra = delegate?.workspaceBar(self, contextMenuItemsForWorkspaceAt: index) ?? []
        if !extra.isEmpty {
            extra.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        // Close
        if !item.isPinned {
            let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = index
            menu.addItem(closeItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextEditWorkspace(_ sender: NSMenuItem) {
        editWorkspace(at: sender.tag)
    }

    /// Ask the delegate to show the inline editor for the pill at `index`.
    func editWorkspace(at index: Int) {
        guard index >= 0, index < items.count else { return }
        delegate?.workspaceBar(self, editWorkspaceAt: index, anchor: verticalItemRect(at: index))
    }

    @objc private func contextMoveToNewWindow(_ sender: NSMenuItem) {
        delegate?.workspaceBar(self, moveWorkspaceToNewWindowAt: sender.tag)
    }

    @objc private func contextTogglePin(_ sender: NSMenuItem) {
        delegate?.workspaceBar(self, togglePinForWorkspaceAt: sender.tag)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        delegate?.workspaceBar(self, didCloseAt: sender.tag)
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

    // MARK: - Hover Tracking

    private func updateWSBarTrackingArea() {
        guard wsBarTrackingArea?.rect != bounds else { return }
        if let existing = wsBarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        wsBarTrackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A taller strip can fit more pills, so a previously valid offset may now
        // scroll past the end.
        clampVerticalScroll()
        updateWSBarTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        updateVerticalHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Recompute what the cursor is over. Called on mouse move and after a scroll,
    /// since scrolling moves the pills out from under a stationary cursor.
    private func updateVerticalHover(at point: NSPoint) {
        let newHover = hitTestItemIndex(at: point) ?? -1
        let newPlusHover = isPlusButtonHit(at: point)
        let newGroup = newHover >= 0 ? nil : hitTestGroupHeader(at: point)
        if newGroup?.id != hoveredGroupID {
            hoveredGroupID = newGroup?.id
            // Only a few letters fit in the strip; the tooltip carries the full name.
            toolTip = newGroup.map { "\($0.name) (\($0.members.count))" }
            needsDisplay = true
        }
        var newCloseHover = false
        if newHover >= 0, newHover < items.count, !items[newHover].isPinned {
            newCloseHover = verticalCloseButtonRect(in: verticalHoveredPillRect(at: newHover)).contains(point)
        }
        if newHover != hoveredIndex || newPlusHover != isPlusButtonHovered
            || newCloseHover != isCloseButtonHovered
        {
            hoveredIndex = newHover
            isPlusButtonHovered = newPlusHover
            isCloseButtonHovered = newCloseHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        var changed = false
        if hoveredIndex != -1 {
            hoveredIndex = -1
            changed = true
        }
        if isPlusButtonHovered {
            isPlusButtonHovered = false
            changed = true
        }
        isCloseButtonHovered = false
        if hoveredGroupID != nil {
            hoveredGroupID = nil
            toolTip = nil
            changed = true
        }
        if changed { needsDisplay = true }
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard isVertical, maxVerticalScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Mirror of the top bar, along Y. Trackpads report both axes on a diagonal
        // swipe, so take whichever the user moved further and let a horizontal
        // flick scroll the vertical strip too.
        let delta =
            abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        verticalScrollOffset -= delta
        clampVerticalScroll()
        // The pill under the cursor changed even though the cursor did not move.
        updateVerticalHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Keep the active workspace on screen — the vertical twin of the top bar's
    /// `scrollToActiveWorkspace`.
    private func scrollToSelectedVertical() {
        guard isVertical, verticalScrollViewportHeight > 0, selectedIndex >= 0,
            selectedIndex < items.count
        else {
            return
        }
        var top = selectedIndex < rowTops.count ? rowTops[selectedIndex] : 0
        // Bring the group header into view with its first member.
        if let header = groupHeaders.first(where: { $0.members.first == selectedIndex }) {
            top = header.top
        }
        if top < verticalScrollOffset {
            verticalScrollOffset = top
        } else if top + Self.verticalItemSize > verticalScrollOffset + verticalScrollViewportHeight {
            verticalScrollOffset = top + Self.verticalItemSize - verticalScrollViewportHeight
        }
        clampVerticalScroll()
    }

    // MARK: - Hit Testing

    private func hitTestItemIndex(at point: NSPoint) -> Int? {
        // The pinned `+` sits on top of the stack, so a pill scrolled underneath
        // it must not steal the hover or the click.
        if verticalPlusRect.contains(point) { return nil }
        // Staying on the already-expanded pill keeps it expanded — otherwise moving
        // toward its close button would collapse it out from under the cursor.
        if hoveredIndex >= 0, hoveredIndex < items.count,
            verticalHoveredPillRect(at: hoveredIndex).contains(point)
        {
            return hoveredIndex
        }
        for (i, _) in items.enumerated() where !hiddenRows.contains(i) {
            // Full strip width so the padding either side of the pill still hovers
            // the workspace it belongs to.
            let r = verticalItemRect(at: i)
            let strip = CGRect(
                x: verticalStripX, y: r.minY, width: Self.verticalWidth, height: r.height)
            if strip.contains(point) { return i }
        }
        return nil
    }

    private func isPlusButtonHit(at point: NSPoint) -> Bool {
        verticalPlusRect.contains(point)
    }

    private func handleVerticalClick(_ point: NSPoint) {
        // The pinned `+` overlays the bottom of the stack; it is handled by
        // `isPlusButtonHit` before we get here, so a pill behind it never matches.
        if verticalPlusRect.contains(point) { return }
        for (i, item) in items.enumerated() where !hiddenRows.contains(i) {
            // The hovered workspace is expanded, so its click target is the wide pill
            // the user can actually see, not the resting strip footprint.
            let pillRect =
                i == hoveredIndex ? verticalHoveredPillRect(at: i) : verticalItemRect(at: i)

            // The close button is inset on the pill's inner edge; test it before the
            // pill so a click on it isn't swallowed as a workspace selection.
            let closeRect = verticalCloseButtonRect(in: pillRect)
            if !item.isPinned && i == hoveredIndex && closeRect.contains(point) {
                delegate?.workspaceBar(self, didCloseAt: i)
                return
            }

            if pillRect.contains(point) {
                delegate?.workspaceBar(self, didSelectAt: i)
                return
            }
        }
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
