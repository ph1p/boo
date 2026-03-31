import Cocoa

protocol ToolbarViewDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didSelectTabAt index: Int)
    func toolbar(_ toolbar: ToolbarView, didCloseTabAt index: Int)
    func toolbarDidRequestNewTab(_ toolbar: ToolbarView)
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView)
    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String)
    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor)
    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor)
    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int)
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int)
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
    }

    struct TabItem {
        let title: String
        let isActive: Bool
    }

    private(set) var workspaces: [WorkspaceItem] = []
    private(set) var tabs: [TabItem] = []
    var sidebarVisible = false
    /// Whether the sidebar button should be hidden (no active plugins).
    var sidebarButtonHidden = false
    /// When true, workspace pills are hidden (they're shown in a left workspace bar instead).
    var hideWorkspaces = false
    var tabScrollOffset: CGFloat = 0
    var workspaceScrollOffset: CGFloat = 0
    var mouseDownLocation: NSPoint?
    var dragSourceIndex: Int?
    var dropTargetIndex: Int?
    var colorPickerIndex: Int = 0
    var colorPickerActive: Bool = false

    // Ghost drag state
    var ghostWindow: NSWindow?
    var isDragging: Bool = false

    // Hover state
    var hoveredWorkspaceIndex: Int = -1
    var hoveredTabIndex: Int = -1
    var isSidebarButtonHovered: Bool = false
    var isPlusButtonHovered: Bool = false
    private var toolbarTrackingArea: NSTrackingArea?

    let barHeight: CGFloat = 38
    let tabFixedWidth: CGFloat = 140

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
        clampScrollOffset()
        updateTrackingArea()
        needsDisplay = true
    }

    // MARK: - Hover Tracking

    private func updateTrackingArea() {
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

        // Sidebar button
        let sidebarHover = !sidebarButtonHidden && point.x >= bounds.width - sidebarButtonWidth
        if sidebarHover != isSidebarButtonHovered {
            isSidebarButtonHovered = sidebarHover
            changed = true
        }

        // Workspace zone
        var newWSHover = -1
        if !hideWorkspaces && point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap && !sidebarHover {
            var x = trafficLightWidth - workspaceScrollOffset
            for (i, ws) in workspaces.enumerated() {
                let w = measureWorkspace(ws)
                if point.x >= x && point.x < x + w + 6 {
                    newWSHover = i
                    break
                }
                x += w + 6
            }
        }
        if newWSHover != hoveredWorkspaceIndex {
            hoveredWorkspaceIndex = newWSHover
            changed = true
        }

        // Tab zone
        var newTabHover = -1
        var newPlusHover = false
        if point.x >= tabZoneStart && point.x <= tabZoneEnd && !sidebarHover {
            var x = tabZoneStart - tabScrollOffset
            for (i, _) in tabs.enumerated() {
                if point.x >= x && point.x < x + tabFixedWidth {
                    newTabHover = i
                    break
                }
                x += tabFixedWidth
            }
            if newTabHover == -1 && point.x >= x && point.x < x + 28 {
                newPlusHover = true
            }
        }
        if newTabHover != hoveredTabIndex {
            hoveredTabIndex = newTabHover
            changed = true
        }
        if newPlusHover != isPlusButtonHovered {
            isPlusButtonHovered = newPlusHover
            changed = true
        }

        if changed { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        let changed =
            hoveredWorkspaceIndex != -1 || hoveredTabIndex != -1 || isSidebarButtonHovered || isPlusButtonHovered
        hoveredWorkspaceIndex = -1
        hoveredTabIndex = -1
        isSidebarButtonHovered = false
        isPlusButtonHovered = false
        if changed { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, colorPickerActive {
            // Clear color panel target to prevent retain leak
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            colorPickerActive = false
        }
        // Recalculate now that traffic light positions are available
        clampScrollOffset()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func update(workspaces: [WorkspaceItem], tabs: [TabItem], sidebarVisible: Bool) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.sidebarVisible = sidebarVisible
        scrollToActiveWorkspace()
        clampScrollOffset()
        needsDisplay = true
    }

    /// Ensure the active workspace pill is visible in the scroll area.
    private func scrollToActiveWorkspace() {
        guard bounds.width > 0 else { return }
        guard let activeIndex = workspaces.firstIndex(where: { $0.isActive }) else { return }
        var x: CGFloat = 0
        for i in 0..<activeIndex {
            x += measureWorkspace(workspaces[i]) + 6
        }
        let activeWidth = measureWorkspace(workspaces[activeIndex]) + 6
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

    /// Actual width past the traffic light buttons, computed from window.
    var trafficLightWidth: CGFloat {
        guard let window = window else { return trafficLightMinWidth }
        // The zoom button is the rightmost traffic light
        if let zoom = window.standardWindowButton(.zoomButton) {
            let frame = zoom.convert(zoom.bounds, to: nil)
            let inContentView = convert(frame, from: nil)
            return max(trafficLightMinWidth, inContentView.maxX + 12)
        }
        return trafficLightMinWidth
    }
    var sidebarButtonWidth: CGFloat { sidebarButtonHidden ? 10 : 38 }
    let dividerWidth: CGFloat = 1
    let zoneGap: CGFloat = 12

    /// Total content width of all workspace pills.
    var totalWorkspaceContentWidth: CGFloat {
        var w: CGFloat = 0
        for ws in workspaces {
            w += measureWorkspace(ws) + 6
        }
        return w
    }

    /// The workspace zone fills all space after the traffic lights.
    var workspaceZoneMaxWidth: CGFloat {
        max(60, bounds.width - trafficLightWidth - zoneGap)
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

    // Tab zone (unused when tabs are in PaneView, kept for compatibility)
    var tabZoneStart: CGFloat {
        workspaceZoneEnd + zoneGap + dividerWidth + zoneGap
    }

    var tabZoneEnd: CGFloat {
        bounds.width - 8
    }

    var tabZoneWidth: CGFloat {
        max(0, tabZoneEnd - tabZoneStart)
    }

    var totalTabContentWidth: CGFloat {
        CGFloat(tabs.count) * tabFixedWidth + 28  // +28 for plus button
    }

    var maxScrollOffset: CGFloat {
        max(0, totalTabContentWidth - tabZoneWidth)
    }

    func measureWorkspace(_ ws: WorkspaceItem) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: ws.isActive ? .medium : .regular)
        ]
        var w = (ws.name as NSString).size(withAttributes: attrs).width + 18
        if ws.isPinned { w += 12 }
        if !ws.isPinned { w += 16 }  // Space for close button on hover
        return w
    }

    func clampScrollOffset() {
        tabScrollOffset = min(max(0, tabScrollOffset), maxScrollOffset)
        workspaceScrollOffset = min(max(0, workspaceScrollOffset), maxWorkspaceScrollOffset)
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

        var x = trafficLightWidth - workspaceScrollOffset
        var idx = workspaces.count
        for (i, ws) in workspaces.enumerated() {
            let w = measureWorkspace(ws)
            if point.x < x + (w + 6) / 2 {
                idx = i
                break
            }
            x += w + 6
        }
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
