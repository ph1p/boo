import Cocoa

@MainActor protocol ToolbarViewDelegate: AnyObject {
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
    func toolbarDidRequestNewWorkspace(_ toolbar: ToolbarView)
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
    }

    struct TabItem {
        let title: String
        let isActive: Bool
    }

    // MARK: - Font Cache (avoids NSFont alloc on every draw pass)

    enum Fonts {
        nonisolated(unsafe) static let ws11Regular = NSFont.systemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let ws11Medium = NSFont.systemFont(ofSize: 11, weight: .medium)
        nonisolated(unsafe) static let tab11Regular = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        nonisolated(unsafe) static let tab11Medium = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        nonisolated(unsafe) static let closeSmall = NSFont.systemFont(ofSize: 8, weight: .bold)
        nonisolated(unsafe) static let plus9Bold = NSFont.systemFont(ofSize: 9, weight: .bold)
        nonisolated(unsafe) static let plus15Light = NSFont.systemFont(ofSize: 15, weight: .light)
    }

    // MARK: - Measure Cache

    /// Cached pill widths keyed by workspace index. Cleared on every `update()` call.
    private var _measureCache: [Int: CGFloat] = [:]
    private var _cachedTotalWorkspaceWidth: CGFloat?

    // MARK: - Traffic Light Width Cache

    private var _cachedTrafficLightWidth: CGFloat?

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
    var isWorkspacePlusButtonHovered: Bool = false
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
            for i in workspaces.indices {
                let w = measureWorkspace(at: i)
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

        // Workspace plus button
        let newWSPlusHover = !hideWorkspaces && workspacePlusButtonRect.contains(point) && !sidebarHover
        if newWSPlusHover != isWorkspacePlusButtonHovered {
            isWorkspacePlusButtonHovered = newWSPlusHover
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
            || isWorkspacePlusButtonHovered
        hoveredWorkspaceIndex = -1
        hoveredTabIndex = -1
        isSidebarButtonHovered = false
        isPlusButtonHovered = false
        isWorkspacePlusButtonHovered = false
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
        _cachedTrafficLightWidth = nil
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
        _measureCache.removeAll(keepingCapacity: true)
        _cachedTotalWorkspaceWidth = nil
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
            x += measureWorkspace(at: i) + 6
        }
        let activeWidth = measureWorkspace(at: activeIndex) + 6
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
        if let window = window, let zoom = window.standardWindowButton(.zoomButton) {
            let frame = zoom.convert(zoom.bounds, to: nil)
            let inContentView = convert(frame, from: nil)
            value = max(trafficLightMinWidth, inContentView.maxX + 12)
        } else {
            value = trafficLightMinWidth
        }
        _cachedTrafficLightWidth = value
        return value
    }
    var sidebarButtonWidth: CGFloat { sidebarButtonHidden ? 10 : 38 }
    let dividerWidth: CGFloat = 1
    let zoneGap: CGFloat = 12

    /// Total content width of all workspace pills (cached until next `update()`).
    var totalWorkspaceContentWidth: CGFloat {
        if let cached = _cachedTotalWorkspaceWidth { return cached }
        var w: CGFloat = 0
        for (i, _) in workspaces.enumerated() {
            w += measureWorkspace(at: i) + 6
        }
        _cachedTotalWorkspaceWidth = w
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

    /// The `+` button rect for adding a new workspace (top bar only).
    var workspacePlusButtonRect: CGRect {
        let btnSize: CGFloat = 24
        let x = workspaceZoneEnd
        let y = (barHeight - btnSize) / 2
        return CGRect(x: x, y: y, width: btnSize, height: btnSize)
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

    /// Measure workspace pill by index, using the measure cache.
    func measureWorkspace(at index: Int) -> CGFloat {
        if let cached = _measureCache[index] { return cached }
        let ws = workspaces[index]
        let font = ws.isActive ? Fonts.ws11Medium : Fonts.ws11Regular
        var w = (ws.name as NSString).size(withAttributes: [.font: font]).width + 20
        if ws.isPinned { w += 12 }
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
        var w = (ws.name as NSString).size(withAttributes: [.font: font]).width + 20
        if ws.isPinned { w += 12 }
        return w
    }

    func clampScrollOffset() {
        tabScrollOffset = min(max(0, tabScrollOffset), maxScrollOffset)
        workspaceScrollOffset = min(max(0, workspaceScrollOffset), maxWorkspaceScrollOffset)
    }

    /// Returns the screen-space rect for each workspace pill, used for tab-drag hover detection.
    func workspacePillScreenFrames() -> [(index: Int, screenFrame: NSRect)] {
        guard let window = window, !hideWorkspaces else { return [] }
        var result: [(Int, NSRect)] = []
        var x = trafficLightWidth - workspaceScrollOffset
        for i in workspaces.indices {
            let w = measureWorkspace(at: i)
            let pillH: CGFloat = 24
            let pillY = (barHeight - pillH) / 2
            let localRect = NSRect(x: x, y: pillY, width: w, height: pillH)
            let windowRect = convert(localRect, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            result.append((i, screenRect))
            x += w + 6
        }
        return result
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
        for i in workspaces.indices {
            let w = measureWorkspace(at: i)
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
