import Cocoa

/// Where a tab can be dropped relative to a pane.
enum TabDropZone: Equatable {
    case tabBarInsert(index: Int)  // insert at position in tab bar
    case left  // left 20% — split horizontally, new pane on left
    case right  // right 20% — split horizontally, new pane on right
    case top  // top 20% — split vertically, new pane on top
    case bottom  // bottom 20% — split vertically, new pane on bottom
}

/// Centralized drag state machine for cross-pane tab drag & drop.
/// Owned by MainWindowController; PaneViews hold a weak reference.
class TabDragCoordinator {
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

    /// All pane views in the current workspace, set by the window controller.
    var paneViews: [UUID: PaneView] = [:]

    // Drag state
    private var sourcePaneView: PaneView?
    private var sourceTabIndex: Int?
    private var ghostWindow: NSWindow?
    private var indicator: TabDropIndicatorView?
    private var tabInsertIndicator: TabInsertionIndicatorView?
    private var eventMonitor: Any?
    private var currentDropTarget: (PaneView, TabDropZone)?

    // Workspace hover state
    private var hoveredWorkspaceIndex: Int?
    private var workspaceHoverTimer: Timer?
    /// Internal so tests can shorten the hover arm time without touching runtime defaults.
    var workspaceHoverDelay: TimeInterval = 0.5
    private var cachedPillFrames: [(index: Int, screenFrame: NSRect)]?

    private let edgeFraction: CGFloat = 0.2

    deinit { cleanup() }

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
        guard let source = sourcePaneView,
            let tabIdx = sourceTabIndex,
            let (dest, zone) = currentDropTarget
        else {
            cleanup()
            return
        }

        // Same-pane tab bar drop: reorder in place
        if source.paneID == dest.paneID, case .tabBarInsert(let insertIdx) = zone {
            let targetIdx = insertIdx > tabIdx ? insertIdx - 1 : insertIdx
            if targetIdx != tabIdx {
                source.pane.moveTab(from: tabIdx, to: targetIdx)
                source.needsDisplay = true
            }
            cleanup()
            return
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .leftMouseDragged:
                self.handleDrag(event)
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
            self?.onWorkspaceHover?(idx)
            self?.workspaceHoverTimer = nil
        }
    }

    private func hitTestPaneViews(event: NSEvent) {
        guard let sourceView = sourcePaneView else { return }
        let screenPoint = event.locationInWindow
        guard let eventWindow = event.window ?? sourceView.window else { return }
        let screenLoc = eventWindow.convertPoint(toScreen: screenPoint)

        var foundTarget: (PaneView, TabDropZone)?

        for (_, pv) in paneViews {
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
                pv.autoscrollTabBar(localX: localPoint.x)
            }
            showIndicator(on: pv, zone: zone)
        } else {
            currentDropTarget = nil
            indicator?.removeFromSuperview()
            indicator = nil
            tabInsertIndicator?.removeFromSuperview()
            tabInsertIndicator = nil
        }
    }

    private func dropZone(in paneView: PaneView, at point: NSPoint) -> TabDropZone {
        let bounds = paneView.bounds

        // PaneView is flipped (isFlipped = true), so y=0 is top.
        // Tab bar region: show insertion indicator between tabs.
        if point.y < paneView.tabBarHeight {
            let idx = paneView.tabInsertionIndex(at: point)
            return .tabBarInsert(index: idx)
        }

        // Terminal area: edges → split, center → append to tab bar
        let termY = point.y - paneView.tabBarHeight
        let termH = bounds.height - paneView.tabBarHeight
        let w = bounds.width
        let edgeW = w * edgeFraction
        let edgeH = termH * edgeFraction

        if point.x < edgeW { return .left }
        if point.x > w - edgeW { return .right }
        if termY < edgeH { return .top }
        if termY > termH - edgeH { return .bottom }

        // Center of terminal → append tab
        return .tabBarInsert(index: paneView.tabCount)
    }

    // MARK: - Drop indicator

    private func showIndicator(on paneView: PaneView, zone: TabDropZone) {
        guard let contentView = paneView.window?.contentView else { return }

        let paneRect = paneView.convert(paneView.bounds, to: contentView)

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

            // Compute position of the insertion gap in pane-local coords
            let localPt = paneView.tabInsertionPosition(at: index)
            // Convert x via the pane-local point; y we compute manually because
            // PaneView is flipped but contentView is not.
            let contentPt = paneView.convert(NSPoint(x: localPt.x, y: 0), to: contentView)
            // paneRect.maxY is the top of the pane in contentView (unflipped) coords.
            // Subtract the row's y offset (in flipped coords, larger y = lower row).
            let rowY = localPt.y
            let barTop = paneRect.maxY
            let lineHeight: CGFloat = 20
            let lineWidth: CGFloat = 3
            insertInd.frame = NSRect(
                x: contentPt.x - lineWidth / 2,
                y: barTop - rowY - lineHeight - 3,
                width: lineWidth, height: lineHeight)

        case .left, .right, .top, .bottom:
            // Hide tab insertion indicator
            tabInsertIndicator?.removeFromSuperview()
            tabInsertIndicator = nil

            // Show blue split overlay
            if indicator == nil {
                indicator = TabDropIndicatorView(frame: .zero)
            }
            guard let indicator = indicator else { return }

            if indicator.superview !== contentView {
                indicator.removeFromSuperview()
                contentView.addSubview(indicator)
            }

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
            default:
                return
            }
            indicator.frame = indicatorRect
        }
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
        ghostView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
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
