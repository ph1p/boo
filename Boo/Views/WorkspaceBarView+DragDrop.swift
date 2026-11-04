import Cocoa

extension WorkspaceBarView {
    // MARK: - Group Drag

    /// Click on a header toggles the group; dragging it moves the whole group
    /// within the strip or, released outside the window, into another window.
    func handleGroupHeaderMouseDown(startPoint: NSPoint, header: GroupHeader) {
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

    func createGhostWindow(for index: Int, event: NSEvent) {
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

    func handleDragMove(_ event: NSEvent) {
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

    func executeDrop() {
        guard let sourceIdx = dragSourceIndex else { return }
        if let gid = dropGroupID {
            delegate?.workspaceBar(self, moveWorkspaceAt: sourceIdx, intoGroup: gid)
        } else if let target = dropStackIndex {
            delegate?.workspaceBar(self, stackWorkspaceAt: sourceIdx, onto: target)
        } else if let dropIdx = dropTargetIndex {
            delegate?.workspaceBar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
        }
    }

    func cleanupDrag() {
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
}
