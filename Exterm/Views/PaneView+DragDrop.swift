import Cocoa

extension PaneView {

    // MARK: - Tab Hit Testing

    func tabIndex(at point: NSPoint) -> Int? {
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .wrap {
            let layouts = wrapLayout()
            for i in 0..<layouts.count {
                let lay = layouts[i]
                if point.y >= lay.y && point.y < lay.y + singleRowTabHeight &&
                   point.x >= lay.x && point.x < lay.x + lay.width {
                    return i
                }
            }
            return nil
        } else {
            let widths = allTabWidths()
            let adjusted = point.x + tabScrollOffset
            var cx: CGFloat = 0
            for i in 0..<widths.count {
                let w = widths[i]
                if adjusted >= cx && adjusted < cx + w { return i }
                cx += w
            }
            return nil
        }
    }

    // MARK: - Scroll Wheel

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < tabBarHeight, AppSettings.shared.tabOverflowMode == .scroll else {
            super.scrollWheel(with: event)
            return
        }
        let maxScroll = scrollMaxOffset()
        guard maxScroll > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Accept both horizontal and vertical scrolling for tab bar (match ToolbarView convention)
        tabScrollOffset -= event.scrollingDeltaX
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            tabScrollOffset += event.scrollingDeltaY
        }
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        needsDisplay = true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !pane.tabs.isEmpty, point.y < tabBarHeight else { return }

        if let idx = tabIndex(at: point) {
            // Compute close button hit zone using variable-width tabs
            let mode = AppSettings.shared.tabOverflowMode
            let localX: CGFloat
            let w: CGFloat
            if mode == .wrap {
                let layouts = wrapLayout()
                let lay = layouts[idx]
                localX = point.x - lay.x
                w = lay.width
            } else {
                let widths = allTabWidths()
                var cx: CGFloat = 0
                for i in 0..<idx { cx += widths[i] }
                localX = (point.x + tabScrollOffset) - cx
                w = widths[idx]
            }
            if showTabClose && localX > w - 18 {
                paneDelegate?.paneView(self, didRequestCloseTab: idx, paneID: paneID)
            } else {
                dragTabIndex = idx
                dragStartPoint = point
                dragCurrentX = nil
            }
            return
        }

        // Plus button
        addNewTab(workingDirectory: pane.activeTab?.workingDirectory ?? "~")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragIdx = dragTabIndex, let startPt = dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Use euclidean distance for threshold
        if dragCurrentX == nil {
            let dx = point.x - startPt.x
            let dy = point.y - startPt.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance > dragThreshold else { return }
        }
        // Hand off to coordinator once threshold is met — it handles both
        // same-pane reorder (via ghost + insertion indicator) and cross-pane drops.
        if let coordinator = tabDragCoordinator {
            coordinator.beginDrag(from: self, tabIndex: dragIdx, event: event)
            dragTabIndex = nil
            dragStartPoint = nil
            dragCurrentX = nil
            needsDisplay = true
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let idx = dragTabIndex {
            // Activate the tab now that mouse is released (click or drag-end)
            activateTab(idx)
        }
        dragTabIndex = nil
        dragStartPoint = nil
        dragCurrentX = nil
        needsDisplay = true
    }

    // MARK: - Drag Auto-scroll

    /// Auto-scroll the tab bar during a drag. Called by the drag coordinator.
    /// `localX` is the cursor x in pane-local coords. Scrolls when near edges.
    func autoscrollTabBar(localX: CGFloat) {
        guard AppSettings.shared.tabOverflowMode == .scroll else { return }
        let maxScroll = scrollMaxOffset()
        guard maxScroll > 0 else { return }
        let edgeZone: CGFloat = 40
        let step: CGFloat = 8
        if localX < edgeZone {
            tabScrollOffset = max(0, tabScrollOffset - step)
            needsDisplay = true
        } else if localX > bounds.width - edgeZone {
            tabScrollOffset = min(maxScroll, tabScrollOffset + step)
            needsDisplay = true
        }
    }

    /// Maximum scroll offset in scroll mode (variable-width tabs).
    func scrollMaxOffset() -> CGFloat {
        let widths = allTabWidths()
        let totalW = widths.reduce(0, +) + plusButtonWidth
        return max(0, totalW - bounds.width)
    }

    // MARK: - Tab Insertion Geometry

    /// Position in pane-local coords for the insertion indicator at a given tab index.
    /// Returns (x, y) where y accounts for the correct row in wrap mode.
    func tabInsertionPosition(at index: Int) -> NSPoint {
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .wrap {
            let layouts = wrapLayout()
            if index < layouts.count {
                return NSPoint(x: layouts[index].x, y: layouts[index].y)
            }
            if let last = layouts.last {
                return NSPoint(x: last.x + last.width, y: last.y)
            }
            return .zero
        } else {
            let widths = allTabWidths()
            var x: CGFloat = 0
            for i in 0..<min(index, widths.count) { x += widths[i] }
            return NSPoint(x: x - tabScrollOffset, y: 0)
        }
    }

    /// Compute the insertion index for a tab bar drop at the given local point.
    func tabInsertionIndex(at point: NSPoint) -> Int {
        let count = pane.tabs.count
        if AppSettings.shared.tabOverflowMode == .wrap {
            let layouts = wrapLayout()
            // Determine which row the point is on
            let row = max(0, Int(point.y / singleRowTabHeight))
            let rowY = CGFloat(row) * singleRowTabHeight
            // Filter to tabs on this row, find insertion point by x
            for i in 0..<layouts.count {
                let lay = layouts[i]
                if lay.y == rowY && point.x < lay.x + lay.width / 2 { return i }
            }
            // Past all tabs on this row — find last tab index on this row + 1
            if let lastOnRow = layouts.lastIndex(where: { $0.y == rowY }) {
                return lastOnRow + 1
            }
            return count
        } else {
            let widths = allTabWidths()
            let adjusted = point.x + tabScrollOffset
            var cx: CGFloat = 0
            for i in 0..<count {
                let w = widths[i]
                if adjusted < cx + w / 2 { return i }
                cx += w
            }
        }
        return count
    }

    /// Average tab width for drag coordinator compatibility.
    func tabWidth() -> CGFloat {
        let widths = allTabWidths()
        guard !widths.isEmpty else { return 100 }
        return widths.reduce(0, +) / CGFloat(widths.count)
    }
}
