import Cocoa

extension PaneView {

    // MARK: - Tab Hit Testing

    func tabIndex(at point: NSPoint) -> Int? {
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .wrap {
            let layouts = wrapLayout()
            for i in 0..<layouts.count {
                let lay = layouts[i]
                if point.y >= lay.y && point.y < lay.y + singleRowTabHeight && point.x >= lay.x
                    && point.x < lay.x + lay.width
                {
                    return i
                }
            }
            return nil
        } else {
            // Exclude the pinned plus button zone on the right
            if point.x >= bounds.width - plusButtonWidth - Self.tabBarSideInset { return nil }
            let widths = allTabWidths()
            let adjusted = point.x + tabScrollOffset
            var cx: CGFloat = Self.tabBarSideInset
            for i in 0..<widths.count {
                let w = widths[i]
                if adjusted >= cx && adjusted < cx + w { return i }
                cx += w
            }
            return nil
        }
    }

    /// Check if a point is over the plus button.
    func isPlusButtonHit(at point: NSPoint) -> Bool {
        plusButtonSlot().contains(point)
    }

    /// Check if a point is over the close button area of a given tab.
    func isOverCloseButton(point: NSPoint, tabIndex idx: Int) -> Bool {
        guard showTabClose else { return false }
        let mode = AppSettings.shared.tabOverflowMode
        let localX: CGFloat
        let w: CGFloat
        if mode == .wrap {
            let layouts = wrapLayout()
            guard idx < layouts.count else { return false }
            let lay = layouts[idx]
            localX = point.x - lay.x
            w = lay.width
        } else {
            let widths = allTabWidths()
            guard idx < widths.count else { return false }
            localX = (point.x + tabScrollOffset) - tabStartX(idx, widths: widths)
            w = widths[idx]
        }
        return localX > w - Self.tabCloseHitZone
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
            if isOverCloseButton(point: point, tabIndex: idx) {
                paneDelegate?.paneView(self, didRequestCloseTab: idx, paneID: paneID)
            } else {
                dragTabIndex = idx
                dragStartPoint = point
                dragCurrentX = nil
            }
            return
        }

        // Plus button — show dropdown menu for tab type selection
        guard isPlusButtonHit(at: point) else { return }
        showNewTabMenu(event: event)
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
            if idx == pane.activeTabIndex {
                focusActiveView()
                if pane.activeTab != nil {
                    paneDelegate?.paneView(self, didFocus: paneID)
                }
            } else {
                activateTab(idx)
            }
        }
        dragTabIndex = nil
        dragStartPoint = nil
        dragCurrentX = nil
        needsDisplay = true
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < tabBarHeight, let idx = tabIndex(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        showTabContextMenu(at: idx, event: event)
    }

    private func showTabContextMenu(at index: Int, event: NSEvent) {
        let menu = NSMenu()

        // Close tab
        let isLastTabInWorkspace = isOnlyTabInWorkspace()
        let closeTitle = isLastTabInWorkspace ? "Close Workspace" : "Close Tab"
        let closeItem = NSMenuItem(title: closeTitle, action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = index
        menu.addItem(closeItem)

        // Move to workspace submenu
        if let workspaces = paneDelegate?.paneViewWorkspaceNames(self), !workspaces.isEmpty {
            menu.addItem(.separator())
            let moveMenu = NSMenu()
            for ws in workspaces {
                let item = NSMenuItem(
                    title: ws.name,
                    action: #selector(contextMoveToWorkspace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = MoveTabAction(tabIndex: index, workspaceIndex: ws.index)
                moveMenu.addItem(item)
            }
            let moveItem = NSMenuItem(title: "Move Tab to Workspace", action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)
        }

        // New tab options
        menu.addItem(.separator())
        for type in ContentType.creatableTypes {
            let item = NSMenuItem(
                title: "New \(type.displayName) Tab",
                action: #selector(contextNewTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = type.icon
            item.representedObject = type
            menu.addItem(item)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextNewTab(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType else { return }
        addNewTab(contentType: type, workingDirectory: pane.activeTab?.workingDirectory ?? "~")
    }

    /// Returns true when closing any tab would leave the workspace empty.
    func isOnlyTabInWorkspace() -> Bool {
        guard pane.tabs.count == 1 else { return false }
        return paneDelegate?.paneViewIsOnlyPaneInWorkspace(self) ?? true
    }

    private struct MoveTabAction {
        let tabIndex: Int
        let workspaceIndex: Int
    }

    @objc private func contextCloseTab(_ sender: NSMenuItem) {
        paneDelegate?.paneView(self, didRequestCloseTab: sender.tag, paneID: paneID)
    }

    @objc private func contextMoveToWorkspace(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MoveTabAction else { return }
        paneDelegate?.paneView(
            self, didRequestMoveTab: action.tabIndex,
            toWorkspaceAt: action.workspaceIndex, paneID: paneID)
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
        scrollMaxOffset(widths: allTabWidths())
    }

    /// Overload for callers that already measured the tabs — `allTabWidths()`
    /// does text layout per title, so don't repeat it within one pass.
    func scrollMaxOffset(widths: [CGFloat]) -> CGFloat {
        let totalW = Self.tabBarSideInset * 2 + widths.reduce(0, +) + plusButtonWidth
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
            let x = tabStartX(min(index, widths.count), widths: widths)
            return NSPoint(x: x - tabScrollOffset, y: 0)
        }
    }

    /// Flipped-coords vertical centre of the pill row at `index` — where the
    /// insertion indicator should centre itself. Scroll mode centres pills in
    /// the whole bar; wrap mode centres them within their row.
    func tabInsertionRowCenterY(at index: Int) -> CGFloat {
        if AppSettings.shared.tabOverflowMode == .wrap {
            let layouts = wrapLayout()
            let rowY = index < layouts.count ? layouts[index].y : (layouts.last?.y ?? Self.tabBarSideInset)
            return rowY + singleRowTabHeight / 2
        }
        return tabBarHeight / 2
    }

    /// Compute the insertion index for a tab bar drop at the given local point.
    func tabInsertionIndex(at point: NSPoint) -> Int {
        let count = pane.tabs.count
        if AppSettings.shared.tabOverflowMode == .wrap {
            let layouts = wrapLayout()
            // Determine which row the point is on (rows start below the bar's top inset)
            let row = max(0, Int((point.y - Self.tabBarSideInset) / singleRowTabHeight))
            let rowY = Self.tabBarSideInset + CGFloat(row) * singleRowTabHeight
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
            var cx: CGFloat = Self.tabBarSideInset
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
