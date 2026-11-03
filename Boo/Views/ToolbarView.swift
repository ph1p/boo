import Cocoa

@MainActor protocol ToolbarViewDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int)
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView)
    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int)
    /// Workspace `source` was dropped onto the pill at `target`: group them.
    func toolbar(_ toolbar: ToolbarView, stackWorkspaceAt source: Int, onto target: Int)
    /// Workspace `source` was dropped onto a group's header chip.
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceAt source: Int, intoGroup groupID: String)
    /// Click on a group's header chip.
    func toolbar(_ toolbar: ToolbarView, toggleGroup groupID: String)
    /// A group header was dragged to insertion index `destination` (whole group moves).
    func toolbar(_ toolbar: ToolbarView, moveGroup groupID: String, to destination: Int)
    /// A group header was dropped outside the window.
    func toolbar(_ toolbar: ToolbarView, dropGroup groupID: String, atScreenPoint point: NSPoint)
    /// Context menu for a group's header chip.
    func toolbar(_ toolbar: ToolbarView, menuItemsForGroup groupID: String) -> [NSMenuItem]
    /// A workspace was dragged out and released outside this window.
    func toolbar(_ toolbar: ToolbarView, dropWorkspaceAt index: Int, atScreenPoint point: NSPoint)
    /// A dragged workspace moved; `point` is the screen point when outside this window, nil otherwise or when the drag ends.
    func toolbar(_ toolbar: ToolbarView, workspaceDragMovedOutsideTo point: NSPoint?)
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceToNewWindowAt index: Int)
    func toolbarDidRequestNewWorkspace(_ toolbar: ToolbarView)
    /// Extra items for a workspace's context menu, shown above Close.
    func toolbar(_ toolbar: ToolbarView, contextMenuItemsForWorkspaceAt index: Int) -> [NSMenuItem]
    /// Open the inline name/color editor for a workspace, anchored on `rect` in the toolbar.
    func toolbar(_ toolbar: ToolbarView, editWorkspaceAt index: Int, anchor rect: NSRect)
}

extension ToolbarViewDelegate {
    func toolbar(_ toolbar: ToolbarView, contextMenuItemsForWorkspaceAt index: Int) -> [NSMenuItem] { [] }
    func toolbar(_ toolbar: ToolbarView, editWorkspaceAt index: Int, anchor rect: NSRect) {}
    func toolbar(_ toolbar: ToolbarView, stackWorkspaceAt source: Int, onto target: Int) {}
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceAt source: Int, intoGroup groupID: String) {}
    func toolbar(_ toolbar: ToolbarView, toggleGroup groupID: String) {}
    func toolbar(_ toolbar: ToolbarView, moveGroup groupID: String, to destination: Int) {}
    func toolbar(_ toolbar: ToolbarView, dropGroup groupID: String, atScreenPoint point: NSPoint) {}
    func toolbar(_ toolbar: ToolbarView, menuItemsForGroup groupID: String) -> [NSMenuItem] { [] }
}

class ToolbarView: NSView {
    weak var delegate: ToolbarViewDelegate?

    struct WorkspaceItem {
        let name: String
        let isActive: Bool
        let resolvedColor: NSColor?  // nil = no color
        let isPinned: Bool
        var color: WorkspaceColor = .none
        var hasCustomColor: Bool = false
        var hasActivity: Bool = false
        var progress: TerminalProgress?
        /// Workspace group; members of one group arrive contiguous (the controller clusters them).
        var groupID: String? = nil
        var groupName: String? = nil
        var groupCollapsed: Bool = false
        var groupColor: NSColor? = nil
    }

    // MARK: - Font Cache (avoids NSFont alloc on every draw pass)

    enum Fonts {
        nonisolated(unsafe) static let ws11Regular = NSFont.systemFont(ofSize: 13, weight: .medium)
        nonisolated(unsafe) static let ws11Medium = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nonisolated(unsafe) static let plus15Light = NSFont.systemFont(ofSize: 17, weight: .light)

        /// The centred header title (active workspace name). Larger than the pill
        /// labels beside it — it names the window, they are navigation.
        nonisolated(unsafe) static let headerTitle = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    // MARK: - Measure Cache

    /// Cached pill widths keyed by workspace index. Cleared on every `update()` call.
    private var _measureCache: [Int: CGFloat] = [:]
    /// Pill and group positions, rebuilt lazily after every `update()`.
    var _cachedLayout: WorkspaceStripLayout?

    // MARK: - Traffic Light Width Cache

    private var _cachedTrafficLightWidth: CGFloat?

    private(set) var workspaces: [WorkspaceItem] = []
    var sidebarVisible = false
    /// When true, workspace pills are hidden (they're shown in a left workspace bar instead).
    var hideWorkspaces = false
    var workspaceScrollOffset: CGFloat = 0
    var mouseDownLocation: NSPoint?
    var dragSourceIndex: Int?
    /// Insertion index while a drag reorders.
    var dropTargetIndex: Int?
    /// Pill the dragged workspace would stack onto (form or join a group).
    var dropStackIndex: Int?
    /// Group header chip the dragged workspace would join.
    var dropGroupID: String?
    /// Group whose header chip is being dragged (the whole group moves).
    var draggedGroupID: String?

    // Ghost drag state
    var ghostWindow: DragGhostWindow?
    var isDragging: Bool = false

    // Hover state
    var hoveredWorkspaceIndex: Int = -1
    var hoveredGroupID: String?
    var isWorkspacePlusButtonHovered: Bool = false
    /// Pointer is over the hovered pill's close button (draws its hover circle).
    var isWorkspaceCloseHovered: Bool = false
    private var toolbarTrackingArea: NSTrackingArea?

    /// The layout constrains the toolbar to `IslandMetrics.toolbarHeight(for:)`;
    /// drawing and hit-testing centre on the laid-out height so the chrome follows
    /// the compact header too. Falls back to the full height before layout.
    var barHeight: CGFloat { bounds.height > 0 ? bounds.height : IslandMetrics.toolbarHeight }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([WorkspaceBarView.workspaceIndexPBType])
        updateTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        _cachedTrafficLightWidth = nil
        clampScrollOffset()
        updateTrackingArea()
        needsDisplay = true
    }

    // MARK: - Hover Tracking

    private func updateTrackingArea() {
        guard toolbarTrackingArea?.rect != bounds else { return }
        if let existing = toolbarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        toolbarTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var changed = false

        // Workspace zone — same pill-band hit test as clicks
        var newWSHover = -1
        if !hideWorkspaces, let idx = hitTestWorkspaceIndex(at: point) {
            newWSHover = idx
        }
        if newWSHover != hoveredWorkspaceIndex {
            hoveredWorkspaceIndex = newWSHover
            changed = true
        }
        var newCloseHover = false
        if newWSHover >= 0, newWSHover < workspaces.count, !workspaces[newWSHover].isPinned,
            workspaces[newWSHover].isActive,
            let pill = workspacePillRect(at: newWSHover)
        {
            newCloseHover = workspaceCloseButtonRect(in: pill).contains(point)
        }
        if newCloseHover != isWorkspaceCloseHovered {
            isWorkspaceCloseHovered = newCloseHover
            changed = true
        }
        let newGroupHover = hideWorkspaces ? nil : hitTestGroupChip(at: point)?.id
        if newGroupHover != hoveredGroupID {
            hoveredGroupID = newGroupHover
            changed = true
        }

        // Workspace plus button
        let newWSPlusHover = !hideWorkspaces && workspacePlusButtonRect.contains(point)
        if newWSPlusHover != isWorkspacePlusButtonHovered {
            isWorkspacePlusButtonHovered = newWSPlusHover
            changed = true
        }

        if changed { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        let changed = hoveredWorkspaceIndex != -1 || isWorkspacePlusButtonHovered || hoveredGroupID != nil
        hoveredWorkspaceIndex = -1
        hoveredGroupID = nil
        isWorkspacePlusButtonHovered = false
        isWorkspaceCloseHovered = false
        if changed { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _cachedTrafficLightWidth = nil
        clampScrollOffset()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func update(workspaces: [WorkspaceItem], sidebarVisible: Bool) {
        self.workspaces = workspaces
        self.sidebarVisible = sidebarVisible
        _measureCache.removeAll(keepingCapacity: true)
        _cachedLayout = nil
        scrollToActiveWorkspace()
        clampScrollOffset()
        needsDisplay = true
    }

    /// Ensure the active workspace pill is visible in the scroll area.
    private func scrollToActiveWorkspace() {
        guard bounds.width > 0 else { return }
        guard let activeIndex = workspaces.firstIndex(where: { $0.isActive }) else { return }
        let x = workspaceLayout.pillX[activeIndex]
        let activeWidth = measureWorkspace(at: activeIndex) + Self.workspaceGap
        let visibleStart = workspaceScrollOffset
        let visibleEnd = workspaceScrollOffset + workspaceZoneWidth

        if x < visibleStart {
            workspaceScrollOffset = x
        } else if x + activeWidth > visibleEnd {
            workspaceScrollOffset = x + activeWidth - workspaceZoneWidth
        }
    }

    // MARK: - Layout constants

    /// Minimum width reserved for traffic lights; used as fallback.
    private let trafficLightMinWidth: CGFloat = 78

    /// Actual width past the traffic light buttons, computed from window (cached per layout pass).
    var trafficLightWidth: CGFloat {
        if let cached = _cachedTrafficLightWidth { return cached }
        let value: CGFloat
        if let window = window, let close = window.standardWindowButton(.closeButton),
            let zoom = window.standardWindowButton(.zoomButton)
        {
            // From the positioner's geometry rather than the buttons' live frames:
            // those may still be at their native spot when this is first cached.
            // The cluster keeps the same gap on its right as on its left.
            let inset = TrafficLightPositioner.edgeInset(
                buttonHeight: close.frame.height, headerHeight: barHeight)
            let cluster = zoom.frame.maxX - close.frame.minX
            value = max(trafficLightMinWidth, ceil(inset + cluster + inset))
        } else {
            value = trafficLightMinWidth
        }
        _cachedTrafficLightWidth = value
        return value
    }
    /// Gap *between* the toolbar's zones (traffic lights | workspaces | plus
    /// button). Deliberately not `contentInset` — that one measures from an edge,
    /// this one separates two runs of content and needs to read as a break.
    let zoneGap: CGFloat = 12

    /// Total content width of the strip, group trays included (cached until next `update()`).
    var totalWorkspaceContentWidth: CGFloat { workspaceLayout.totalWidth }

    /// Gap between adjacent workspace pills. Matches `plusLeadingGap` so the
    /// spacing is even all the way across the strip, including up to the `+`.
    static let workspaceGap: CGFloat = 8

    /// Size of the pinned `+` button.
    static let plusButtonSize: CGFloat = 28

    /// Height of a workspace pill — also the vertical extent of its click/hover
    /// zone, so the bar above and below the pills stays draggable window chrome.
    static let workspacePillHeight: CGFloat = 28

    /// The workspace zone fills all space after the traffic lights, up to the
    /// pinned `+` button at the bar's right end.
    var workspaceZoneMaxWidth: CGFloat {
        max(60, workspacePlusButtonRect.minX - trafficLightWidth)
    }

    /// Visible width of the workspace zone — shrinks to content if it fits, else fills available space.
    var workspaceZoneWidth: CGFloat {
        min(totalWorkspaceContentWidth, workspaceZoneMaxWidth)
    }

    // Workspace zone: after traffic lights, up to sidebar button
    var workspaceZoneEnd: CGFloat {
        trafficLightWidth + workspaceZoneWidth
    }

    var maxWorkspaceScrollOffset: CGFloat {
        max(0, totalWorkspaceContentWidth - workspaceZoneWidth)
    }

    /// The `+` button rect for adding a new workspace (top bar only). Pinned at
    /// the right end of the bar, inset by the shared island gap so it lines up
    /// with the island edges below, regardless of how many pills there are. The
    /// scrollable pill strip stops short of it, so the right-hand scroll fade
    /// lands in the space between.
    var workspacePlusButtonRect: CGRect {
        let btnSize = Self.plusButtonSize
        // 5pt closer to the edge than the island gap: the button's rounded pill
        // carries visual padding of its own, so the full gap reads too wide.
        let x = bounds.width - (IslandMetrics.gap - 5) - btnSize
        let y = (barHeight - btnSize) / 2
        return CGRect(x: x, y: y, width: btnSize, height: btnSize)
    }

    /// Hover close-button rect for a top-bar pill, right-aligned and vertically
    /// centred. Shared by draw and hit-test so the drawn circle and click target
    /// can't diverge.
    /// Leading padding of a pill's label (and trailing padding of a pinned pill).
    static let workspaceLeadIn: CGFloat = 12
    /// Close circle inset from the pill's trailing edge.
    static let workspaceCloseInset: CGFloat = 5
    /// Trailing slot of an unpinned pill: the close button (or the activity dot
    /// sharing its spot) plus a small gap to the label. The pill keeps this width
    /// whether active or not, so switching workspaces never reflows the bar —
    /// inactive pills just centre the label across lead-in + slot.
    static let workspaceCloseSlot: CGFloat = WorkspacePillStyle.closeButtonSize + workspaceCloseInset + 5

    /// Live pointer test: hover flags can go stale when a pill becomes active
    /// under a still mouse, so the close circle double-checks at draw time.
    func isMouseInside(_ rect: CGRect) -> Bool {
        guard let window else { return false }
        return rect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func workspaceCloseButtonRect(in pillRect: CGRect) -> CGRect {
        let size = WorkspacePillStyle.closeButtonSize
        let inset = Self.workspaceCloseInset
        return CGRect(
            x: pillRect.maxX - size - inset,
            y: pillRect.midY - size / 2,
            width: size, height: size)
    }

    /// Measure workspace pill by index, using the measure cache.
    func measureWorkspace(at index: Int) -> CGFloat {
        if let cached = _measureCache[index] { return cached }
        let ws = workspaces[index]
        let font = ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
        var w = (ws.name as NSString).size(withAttributes: [.font: font]).width
        w += ws.isPinned ? Self.workspaceLeadIn * 2 + 13 : Self.workspaceLeadIn + Self.workspaceCloseSlot
        w = max(w, 56)
        _measureCache[index] = w
        return w
    }

    /// Convenience overload for call sites that only have the item (scans for index).
    func measureWorkspace(_ ws: WorkspaceItem) -> CGFloat {
        if let i = workspaces.firstIndex(where: {
            $0.name == ws.name && $0.isActive == ws.isActive && $0.isPinned == ws.isPinned
        }) {
            return measureWorkspace(at: i)
        }
        let font = ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
        var w = (ws.name as NSString).size(withAttributes: [.font: font]).width
        w += ws.isPinned ? Self.workspaceLeadIn * 2 + 13 : Self.workspaceLeadIn + Self.workspaceCloseSlot
        w = max(w, 56)
        return w
    }

    func clampScrollOffset() {
        workspaceScrollOffset = min(max(0, workspaceScrollOffset), maxWorkspaceScrollOffset)
    }

    /// Returns the screen-space rect for each workspace pill, used for tab-drag hover detection.
    func workspacePillScreenFrames() -> [(index: Int, screenFrame: NSRect)] {
        guard let window = window, !hideWorkspaces else { return [] }
        return workspaces.indices.compactMap { i in
            guard let localRect = workspacePillRect(at: i) else { return nil }
            return (i, window.convertToScreen(convert(localRect, to: nil)))
        }
    }
}

// MARK: - NSDraggingSource

extension ToolbarView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

// MARK: - NSDraggingDestination

extension ToolbarView {
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !hideWorkspaces else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else {
            if dropTargetIndex != nil {
                dropTargetIndex = nil
                needsDisplay = true
            }
            return []
        }

        let idx = workspaceInsertionIndex(atX: point.x)
        if idx != dropTargetIndex {
            dropTargetIndex = idx
            needsDisplay = true
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropTargetIndex = nil
            dragSourceIndex = nil
            needsDisplay = true
        }
        guard let dropIdx = dropTargetIndex,
            let pb = sender.draggingPasteboard.string(forType: WorkspaceBarView.workspaceIndexPBType),
            let sourceIdx = Int(pb)
        else { return false }
        guard sourceIdx != dropIdx && sourceIdx + 1 != dropIdx else { return true }
        delegate?.toolbar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTargetIndex = nil
        dragSourceIndex = nil
        needsDisplay = true
    }
}

// MARK: - Accessibility

extension ToolbarView {
    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        guard !hideWorkspaces, let window else { return base }
        var elements: [Any] = []
        for (index, screenFrame) in workspacePillScreenFrames() {
            let ws = workspaces[index]
            let local = convert(window.convertFromScreen(screenFrame), from: nil)
            let label = ws.isPinned ? "Workspace \(ws.name), pinned" : "Workspace \(ws.name)"
            elements.append(
                AccessibleElement(
                    parent: self, role: .radioButton, label: label, localRect: local, selected: ws.isActive
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.toolbar(self, didSelectWorkspaceAt: index)
                })
        }
        elements.append(
            AccessibleElement(
                parent: self, role: .button, label: "New workspace", localRect: workspacePlusButtonRect
            ) { [weak self] in
                guard let self else { return }
                self.delegate?.toolbarDidRequestNewWorkspace(self)
            })
        return elements + base
    }
}
