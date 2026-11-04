import Cocoa

extension WorkspaceBarView {
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

    // MARK: - Hover Tracking

    func updateWSBarTrackingArea() {
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
    func scrollToSelectedVertical() {
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

    func handleVerticalClick(_ point: NSPoint) {
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
