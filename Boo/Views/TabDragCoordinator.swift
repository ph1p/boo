import Cocoa

/// Where a tab can be dropped relative to a pane.
enum TabDropZone: Equatable {
    case tabBarInsert(index: Int)  // insert at position in tab bar
    /// Over the middle of another tab of the same pane: group the two.
    case tabBarGroup(index: Int)
    case left  // near the left edge — new pane on the left of this one
    case right  // near the right edge — new pane on the right of this one
    case top  // near the top edge — new pane above this one
    case bottom  // near the bottom edge — new pane below this one
    case center  // middle of the terminal — append to the pane's tab bar
    /// Thin band along an outer edge of the workspace: the new pane spans
    /// that whole side instead of splitting only the pane under the cursor.
    case workspaceEdge(PaneDirection)
    /// ⌥ held over the middle of another pane in the same workspace: the two
    /// panes trade places instead of the tab moving.
    case swapPanes

    /// Side the new pane goes on, and whether it spans the workspace; nil for
    /// drops that keep the tab in an existing pane.
    var splitPlacement: (edge: PaneDirection, wholeWorkspace: Bool)? {
        switch self {
        case .left: return (.left, false)
        case .right: return (.right, false)
        case .top: return (.up, false)
        case .bottom: return (.down, false)
        case .workspaceEdge(let edge): return (edge, true)
        case .tabBarInsert, .tabBarGroup, .center, .swapPanes: return nil
        }
    }
}

/// Centralized drag state machine for cross-pane tab drag & drop.
/// Owned by MainWindowController; PaneViews hold a weak reference.
@MainActor class TabDragCoordinator {
    /// Callback to execute a cross-pane drop.
    var onDrop:
        (
            (
                _ sourcePaneView: PaneView, _ tabIndex: Int,
                _ destPaneView: PaneView, _ zone: TabDropZone
            ) -> Void
        )?

    /// Called with a workspace index when the cursor hovers over a pill long enough.
    var onWorkspaceHover: ((Int) -> Void)?

    /// Returns (index, screenFrame) pairs for all workspace pills.
    var workspacePillFrames: (() -> [(index: Int, screenFrame: NSRect)])?

    /// Called when a drag ends over no pane, with the screen point.
    var onDropOutside: ((_ sourcePaneView: PaneView, _ tabIndex: Int, _ screenPoint: NSPoint) -> Void)?

    /// Drop candidates at a screen point: the panes of the window in front
    /// there, which may be another window. Nil falls back to `paneViews`.
    var paneViewsAtScreenPoint: ((NSPoint) -> [UUID: PaneView]?)?

    /// All pane views in the current workspace, set by the window controller.
    var paneViews: [UUID: PaneView] = [:]

    // Drag state
    /// Pane the dragged tab came from (internal for tests).
    var sourcePaneView: PaneView?
    private var sourceTabIndex: Int?
    private var ghostWindow: NSWindow?
    private var indicator: TabDropIndicatorView?
    private var tabInsertIndicator: TabInsertionIndicatorView?
    private var swapSourceIndicator: TabDropIndicatorView?
    private var eventMonitor: Any?
    private var currentDropTarget: (PaneView, TabDropZone)?

    // Workspace hover state
    private var hoveredWorkspaceIndex: Int?
    private var workspaceHoverTimer: Timer?
    /// Internal so tests can shorten the hover arm time without touching runtime defaults.
    var workspaceHoverDelay: TimeInterval = 0.5
    private var cachedPillFrames: [(index: Int, screenFrame: NSRect)]?

    private let edgeFraction: CGFloat = 0.2
    /// Top/bottom zones use a larger fraction: pane heights are much smaller
    /// than widths, so 20% of the terminal height was a thin strip the drag
    /// had to reach almost to the edge before a vertical split registered.
    private let verticalEdgeFraction: CGFloat = 0.3

    deinit { MainActor.assumeIsolated { cleanup() } }

    // MARK: - Drag lifecycle

    func beginDrag(from paneView: PaneView, tabIndex: Int, event: NSEvent) {
        sourcePaneView = paneView
        sourceTabIndex = tabIndex
        cachedPillFrames = workspacePillFrames?()

        createGhostWindow(for: paneView, tabIndex: tabIndex, event: event)
        installEventMonitor()
    }

    private func cancelDrag() {
        cleanup()
    }

    private func executeDrop() {
        guard let source = sourcePaneView, let tabIdx = sourceTabIndex else {
            cleanup()
            return
        }
        guard let (dest, zone) = currentDropTarget else {
            cleanup()
            onDropOutside?(source, tabIdx, NSEvent.mouseLocation)
            return
        }

        if isNoOpDrop(on: dest, zone: zone) {
            cleanup()
            return
        }

        if case .tabBarGroup(let target) = zone {
            if source.paneID == dest.paneID, source.pane.groupTab(at: tabIdx, with: target) != nil {
                source.groupsChanged()
            }
            cleanup()
            return
        }

        // Same-pane tab bar (or center-append) drop: reorder in place
        if source.paneID == dest.paneID {
            let insertIdx: Int?
            switch zone {
            case .tabBarInsert(let idx): insertIdx = idx
            case .center: insertIdx = source.pane.tabs.count
            default: insertIdx = nil
            }
            if let insertIdx {
                let targetIdx = insertIdx > tabIdx ? insertIdx - 1 : insertIdx
                if targetIdx != tabIdx {
                    source.pane.moveTab(from: tabIdx, to: targetIdx)
                    source.needsDisplay = true
                }
                cleanup()
                return
            }
        }

        cleanup()
        onDrop?(source, tabIdx, dest, zone)
    }

    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
        indicator?.removeFromSuperview()
        indicator = nil
        tabInsertIndicator?.removeFromSuperview()
        tabInsertIndicator = nil
        hideSwapSourceIndicator()
        swapModifierHeld = false
        sourcePaneView = nil
        sourceTabIndex = nil
        currentDropTarget = nil
        workspaceHoverTimer?.invalidate()
        workspaceHoverTimer = nil
        hoveredWorkspaceIndex = nil
        cachedPillFrames = nil
    }

    // MARK: - Event monitor

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged
        ]) {
            [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .leftMouseDragged:
                self.handleDrag(event)
                return event
            case .flagsChanged:
                // Toggling ⌥ without moving the mouse flips swap ↔ append.
                let held = event.modifierFlags.contains(.option)
                if held != self.swapModifierHeld {
                    self.swapModifierHeld = held
                    self.hitTest(screenPoint: NSEvent.mouseLocation)
                }
                return event
            case .leftMouseUp:
                self.executeDrop()
                return event
            case .keyDown:
                if event.keyCode == 53 {  // Escape
                    self.cancelDrag()
                    return nil  // consume the event
                }
                return event
            default:
                return event
            }
        }
    }

    // MARK: - Drag tracking

    private func handleDrag(_ event: NSEvent) {
        moveGhostWindow(to: event)
        hitTestPaneViews(event: event)
        checkWorkspaceHover(event: event)
    }

    private func checkWorkspaceHover(event: NSEvent) {
        let screenLoc: NSPoint =
            event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        updateWorkspaceHover(screenPoint: screenLoc)
    }

    /// Called by the event path and exposed for testing.
    /// Tests that bypass `beginDrag` can pre-populate the cache via this entry point.
    func simulateHoverAt(screenPoint: NSPoint) {
        if cachedPillFrames == nil { cachedPillFrames = workspacePillFrames?() }
        updateWorkspaceHover(screenPoint: screenPoint)
    }

    private func updateWorkspaceHover(screenPoint: NSPoint) {
        guard let frames = cachedPillFrames else { return }

        let hitIndex = frames.first(where: { $0.screenFrame.contains(screenPoint) })?.index

        guard hitIndex != hoveredWorkspaceIndex else { return }
        hoveredWorkspaceIndex = hitIndex
        workspaceHoverTimer?.invalidate()
        workspaceHoverTimer = nil

        guard let idx = hitIndex else { return }
        workspaceHoverTimer = Timer.scheduledTimer(
            withTimeInterval: workspaceHoverDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onWorkspaceHover?(idx)
                self?.workspaceHoverTimer = nil
            }
        }
    }

    private func hitTestPaneViews(event: NSEvent) {
        guard let sourceView = sourcePaneView else { return }
        guard let eventWindow = event.window ?? sourceView.window else { return }
        swapModifierHeld = event.modifierFlags.contains(.option)
        hitTest(screenPoint: eventWindow.convertPoint(toScreen: event.locationInWindow))
    }

    private func hitTest(screenPoint screenLoc: NSPoint) {
        guard sourcePaneView != nil else { return }
        var foundTarget: (PaneView, TabDropZone)?

        for (_, pv) in paneViewsAtScreenPoint?(screenLoc) ?? paneViews {
            guard let pvWindow = pv.window else { continue }
            let windowPoint = pvWindow.convertPoint(fromScreen: screenLoc)
            let localPoint = pv.convert(windowPoint, from: nil)

            if pv.bounds.contains(localPoint) {
                let zone = dropZone(in: pv, at: localPoint)
                foundTarget = (pv, zone)
                break
            }
        }

        if let (pv, zone) = foundTarget {
            currentDropTarget = (pv, zone)
            // Auto-scroll tab bar when dragging near edges in scroll mode
            if case .tabBarInsert = zone, let pvWindow = pv.window {
                let windowPoint = pvWindow.convertPoint(fromScreen: screenLoc)
                let localPoint = pv.convert(windowPoint, from: nil)
                pv.autoscrollTabBar(local: localPoint)
            }
            if isNoOpDrop(on: pv, zone: zone) {
                hideIndicators()
            } else {
                showIndicator(on: pv, zone: zone)
            }
        } else {
            currentDropTarget = nil
            hideIndicators()
        }
    }

    private func hideIndicators() {
        indicator?.removeFromSuperview()
        indicator = nil
        hideSwapSourceIndicator()
        tabInsertIndicator?.removeFromSuperview()
        tabInsertIndicator = nil
    }

    /// Width of the band along the workspace's outer edges that targets the
    /// whole side rather than the pane under the cursor.
    let workspaceEdgeBand: CGFloat = 16

    func dropZone(in paneView: PaneView, at point: NSPoint) -> TabDropZone {
        let bounds = paneView.bounds

        // PaneView is flipped (isFlipped = true), so y=0 is top.
        // Tab bar region: show insertion indicator between tabs.
        if paneView.isInTabBar(point) {
            if paneView === sourcePaneView, let target = paneView.tabIndex(at: point), target != sourceTabIndex,
                let pill = paneView.visibleTabPillRect(at: target),
                paneView.isVerticalTabs
                    ? point.y > pill.minY + pill.height / 3 && point.y < pill.maxY - pill.height / 3
                    : point.x > pill.minX + pill.width / 3 && point.x < pill.maxX - pill.width / 3
            {
                return .tabBarGroup(index: target)
            }
            let idx = paneView.tabInsertionIndex(at: point)
            return .tabBarInsert(index: idx)
        }

        if let edge = workspaceEdge(of: paneView, at: point) {
            return .workspaceEdge(edge)
        }

        // Terminal area: the nearest edge within its band splits, the middle
        // appends. Scoring by distance relative to each band (instead of
        // checking left/right first) splits corners along the closer edge.
        let termY = point.y - paneView.tabBarHeight
        let termH = max(bounds.height - paneView.tabBarHeight, 1)
        let edgeW = max(bounds.width * edgeFraction, 1)
        let edgeH = max(termH * verticalEdgeFraction, 1)
        let scores: [(TabDropZone, CGFloat)] = [
            (.left, point.x / edgeW),
            (.right, (bounds.width - point.x) / edgeW),
            (.top, termY / edgeH),
            (.bottom, (termH - termY) / edgeH)
        ]
        if let nearest = scores.min(by: { $0.1 < $1.1 }), nearest.1 < 1 {
            return nearest.0
        }

        if swapModifierHeld, canSwap(with: paneView) {
            return .swapPanes
        }

        // Center of terminal → append tab. A distinct zone so the indicator can
        // highlight the whole pane — an insertion line up in the tab bar while
        // the cursor is mid-pane reads as misplaced.
        return .center
    }

    /// Outer workspace edge `point` lies on, when `paneView` touches that edge
    /// and the workspace has more than one pane. The top band sits just below
    /// the tab bar, which owns the pane's very top.
    private func workspaceEdge(of paneView: PaneView, at point: NSPoint) -> PaneDirection? {
        guard let container = splitContainer(of: paneView),
            (container.renderedTree?.leafCount ?? 0) > 1
        else { return nil }
        let pane = paneView.convert(paneView.bounds, to: container)
        let local = paneView.convert(point, to: container)
        let outer = container.bounds
        let band = workspaceEdgeBand
        let tolerance: CGFloat = 1
        // Container coordinates are not flipped: maxY is the top.
        if pane.minX - outer.minX < tolerance, local.x - pane.minX < band { return .left }
        if outer.maxX - pane.maxX < tolerance, pane.maxX - local.x < band { return .right }
        if pane.minY - outer.minY < tolerance, local.y - pane.minY < band { return .down }
        if outer.maxY - pane.maxY < tolerance, point.y - paneView.tabBarHeight < band { return .up }
        return nil
    }

    private func splitContainer(of paneView: PaneView) -> SplitContainerView? {
        sequence(first: paneView as NSView, next: { $0.superview }).lazy
            .compactMap { $0 as? SplitContainerView }.first
    }

    /// Whether dropping the dragged tab on `zone` of `paneView` changes nothing
    /// (a pane's only tab dropped back onto that pane).
    /// True while ⌥ is held during a drag (swap panes instead of moving the tab).
    var swapModifierHeld = false

    /// Panes can swap only with another pane rendered in the source's split container.
    private func canSwap(with paneView: PaneView) -> Bool {
        // A source pane moved out of the container (cross-workspace hover) has none.
        guard let source = sourcePaneView, source !== paneView,
            let container = splitContainer(of: source)
        else { return false }
        return splitContainer(of: paneView) === container
    }

    private func isNoOpDrop(on paneView: PaneView, zone: TabDropZone) -> Bool {
        guard paneView === sourcePaneView, paneView.pane.tabs.count == 1 else { return false }
        if case .workspaceEdge = zone { return false }
        return true
    }

    // MARK: - Drop indicator

    private func showIndicator(on paneView: PaneView, zone: TabDropZone) {
        guard let contentView = paneView.window?.contentView else { return }

        let paneRect = paneView.convert(paneView.bounds, to: contentView)
        updateSwapSourceIndicator(visible: zone == .swapPanes, in: contentView)

        switch zone {
        case .tabBarInsert(let index):
            // Hide blue split overlay
            indicator?.removeFromSuperview()
            indicator = nil

            // Show vertical insertion line
            if tabInsertIndicator == nil {
                tabInsertIndicator = TabInsertionIndicatorView(frame: .zero)
            }
            guard let insertInd = tabInsertIndicator else { return }

            if insertInd.superview !== contentView {
                insertInd.removeFromSuperview()
                contentView.addSubview(insertInd)
            }

            if paneView.isVerticalTabs {
                // Horizontal line across the column, in the gap between rows.
                let y = paneView.tabInsertionPosition(at: index).y
                let inset = PaneView.tabBarSideInset + 4
                let line = CGRect(x: inset, y: y - 1.5, width: paneView.verticalTabColumnWidth - inset * 2, height: 3)
                insertInd.frame = paneView.convert(line, to: contentView)
                return
            }

            // Compute position of the insertion gap in pane-local coords
            let localPt = paneView.tabInsertionPosition(at: index)
            // Convert x via the pane-local point; y we compute manually because
            // PaneView is flipped but contentView is not.
            let contentPt = paneView.convert(NSPoint(x: localPt.x, y: 0), to: contentView)
            // paneRect.maxY is the top of the pane in contentView (unflipped) coords.
            // Centre the line on the pill row it inserts into.
            let rowCenterY = paneView.tabInsertionRowCenterY(at: index)
            let barTop = paneRect.maxY
            let lineHeight: CGFloat = 20
            let lineWidth: CGFloat = 3
            insertInd.frame = NSRect(
                x: contentPt.x - lineWidth / 2,
                y: barTop - rowCenterY - lineHeight / 2,
                width: lineWidth, height: lineHeight)

        case .left, .right, .top, .bottom, .center, .workspaceEdge, .swapPanes, .tabBarGroup:
            // Hide tab insertion indicator
            tabInsertIndicator?.removeFromSuperview()
            tabInsertIndicator = nil

            let indicatorRect: NSRect
            switch zone {
            case .left:
                indicatorRect = NSRect(
                    x: paneRect.minX + 2, y: paneRect.minY + 2,
                    width: paneRect.width * 0.5 - 4, height: paneRect.height - 4)
            case .right:
                indicatorRect = NSRect(
                    x: paneRect.midX + 2, y: paneRect.minY + 2,
                    width: paneRect.width * 0.5 - 4, height: paneRect.height - 4)
            case .top:
                indicatorRect = NSRect(
                    x: paneRect.minX + 2, y: paneRect.midY + 2,
                    width: paneRect.width - 4, height: paneRect.height * 0.5 - 4)
            case .bottom:
                indicatorRect = NSRect(
                    x: paneRect.minX + 2, y: paneRect.minY + 2,
                    width: paneRect.width - 4, height: paneRect.height * 0.5 - 4)
            case .center, .swapPanes:
                // Append to (or swap with) this pane: highlight the whole pane,
                // not a line in the tab bar the cursor is nowhere near.
                indicatorRect = paneRect.insetBy(dx: 2, dy: 2)
            case .workspaceEdge(let edge):
                guard let rect = workspaceEdgeRect(for: paneView, edge: edge, in: contentView) else { return }
                indicatorRect = rect
            case .tabBarGroup(let target):
                guard let pill = paneView.visibleTabPillRect(at: target) else { return }
                indicatorRect = paneView.convert(pill, to: contentView).insetBy(dx: -2, dy: -2)
            default:
                return
            }

            // Show blue split overlay: fade in on first show, then glide
            // between zones so the target reads as one moving preview.
            if let indicator, indicator.superview === contentView {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    indicator.animator().frame = indicatorRect
                }
            } else {
                indicator?.removeFromSuperview()
                let newIndicator = TabDropIndicatorView(frame: indicatorRect)
                newIndicator.alphaValue = 0
                contentView.addSubview(newIndicator)
                indicator = newIndicator
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    newIndicator.animator().alphaValue = 1
                }
            }
        }
    }

    /// Second highlight on the dragged tab's own pane while swapping, so both
    /// panes that trade places light up.
    private func updateSwapSourceIndicator(visible: Bool, in contentView: NSView) {
        guard visible, let source = sourcePaneView else {
            hideSwapSourceIndicator()
            return
        }
        let rect = source.convert(source.bounds, to: contentView).insetBy(dx: 2, dy: 2)
        if let swapSourceIndicator, swapSourceIndicator.superview === contentView {
            swapSourceIndicator.frame = rect
            return
        }
        hideSwapSourceIndicator()
        let view = TabDropIndicatorView(frame: rect)
        contentView.addSubview(view)
        swapSourceIndicator = view
    }

    private func hideSwapSourceIndicator() {
        swapSourceIndicator?.removeFromSuperview()
        swapSourceIndicator = nil
    }

    /// Preview of a whole-workspace drop: the strip along `edge` the new pane
    /// will take, sized like the equal share it gets.
    private func workspaceEdgeRect(for paneView: PaneView, edge: PaneDirection, in contentView: NSView) -> NSRect? {
        guard let container = splitContainer(of: paneView), let tree = container.renderedTree else { return nil }
        let outer = container.convert(container.bounds, to: contentView)
        let share = 1 / CGFloat(tree.weight(along: edge.axis) + 1)
        let rect: NSRect
        switch edge {
        case .left:
            rect = NSRect(x: outer.minX, y: outer.minY, width: outer.width * share, height: outer.height)
        case .right:
            rect = NSRect(
                x: outer.maxX - outer.width * share, y: outer.minY, width: outer.width * share, height: outer.height)
        case .up:
            rect = NSRect(
                x: outer.minX, y: outer.maxY - outer.height * share, width: outer.width, height: outer.height * share)
        case .down:
            rect = NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: outer.height * share)
        }
        return rect.insetBy(dx: 2, dy: 2)
    }

    // MARK: - Ghost window

    private func createGhostWindow(for paneView: PaneView, tabIndex: Int, event: NSEvent) {
        guard tabIndex >= 0, tabIndex < paneView.pane.tabs.count else { return }
        let tab = paneView.pane.tabs[tabIndex]
        let title = tab.title
        let ghostWidth: CGFloat = 140
        let ghostHeight: CGFloat = 26

        let ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
        ghostView.wantsLayer = true
        ghostView.layer?.backgroundColor = AppSettings.shared.theme.dragGhostBg.cgColor
        ghostView.layer?.cornerRadius = 6
        ghostView.layer?.borderColor = NSColor.separatorColor.cgColor
        ghostView.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.labelColor
        label.frame = NSRect(x: 8, y: 4, width: ghostWidth - 16, height: ghostHeight - 8)
        label.lineBreakMode = .byTruncatingTail
        ghostView.addSubview(label)

        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        let win = NSWindow(
            contentRect: NSRect(
                x: screenPoint.x - ghostWidth / 2,
                y: screenPoint.y - ghostHeight / 2,
                width: ghostWidth, height: ghostHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = ghostView
        win.alphaValue = 0.85
        win.orderFront(nil)

        ghostWindow = win
    }

    private func moveGhostWindow(to event: NSEvent) {
        guard let win = ghostWindow else { return }
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        let frame = win.frame
        win.setFrameOrigin(
            NSPoint(
                x: screenPoint.x - frame.width / 2,
                y: screenPoint.y - frame.height / 2))
    }
}
