import Cocoa

// MARK: - Workspace strip layout & groups
//
// Every pill position in the top bar comes from one layout pass, so drawing,
// hit-testing, drop targets and screen frames can't disagree about where a pill
// is once group trays shift things around.
//
// A group draws as a tray behind its members, led by a header chip with the
// group's name. Clicking the chip collapses the group to just the chip (plus the
// active workspace if it is a member); dropping a pill onto the chip joins it.

/// One group's run in the strip. X values are content coordinates (0 = zone
/// start, before scrolling).
struct WorkspaceStripGroup {
    let id: String
    let name: String
    let collapsed: Bool
    let members: Range<Int>
    let trayMinX: CGFloat
    let trayMaxX: CGFloat
    let chipX: CGFloat
    let chipWidth: CGFloat
    /// Unseen activity in a hidden member.
    let hiddenActivity: Bool
    let color: NSColor?
}

struct WorkspaceStripLayout {
    /// Content x of each pill (a hidden pill keeps the slot it would start at).
    var pillX: [CGFloat] = []
    var hidden: Set<Int> = []
    var groups: [WorkspaceStripGroup] = []
    /// Content width including the trailing gap, like the plain pill run before groups.
    var totalWidth: CGFloat = 0
}

extension ToolbarView {
    /// Inset of the chip and member pills from the tray edge, the same on all
    /// four sides; members sit the same distance apart, like segments.
    static let groupInnerPad: CGFloat = 2
    /// Tray height: one pill plus the inner padding above and below.
    static let groupTrayHeight: CGFloat = workspacePillHeight + groupInnerPad * 2
    /// The chip is a full-height segment, so its hover fill lines up with the members.
    static let groupChipHeight: CGFloat = workspacePillHeight

    nonisolated(unsafe) static let groupChipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    nonisolated(unsafe) static let groupCountFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    /// Chip spacing, shared by `chipWidth` and `drawGroupChipContent` so the
    /// measured and drawn chip can't drift apart.
    static let groupChipPadX: CGFloat = 10
    /// Trailing inset of the count badge: tray padding plus this equals the gap
    /// above and below the badge, so the capsule sits evenly in the tray corner.
    static var groupBadgeInset: CGFloat {
        (groupTrayHeight - groupCountHeight) / 2 - groupInnerPad
    }
    static let groupChevronSize: CGFloat = 8
    static let groupChipGap: CGFloat = 6
    static let groupCountHeight: CGFloat = 16

    var workspaceLayout: WorkspaceStripLayout {
        if let cached = _cachedLayout { return cached }
        let layout = buildWorkspaceLayout()
        _cachedLayout = layout
        return layout
    }

    private func chipWidth(name: String, collapsed: Bool, count: Int) -> CGFloat {
        let nameW = ceil((name as NSString).size(withAttributes: [.font: Self.groupChipFont]).width)
        var w = Self.groupChipPadX + Self.groupChevronSize + Self.groupChipGap + nameW + Self.groupChipPadX
        if collapsed {
            w +=
                Self.groupChipGap + WorkspacePillStyle.groupCountBadgeWidth(count, font: Self.groupCountFont)
                + Self.groupBadgeInset - Self.groupChipPadX
        }
        return ceil(min(w, 180))
    }

    private func buildWorkspaceLayout() -> WorkspaceStripLayout {
        let gap = Self.workspaceGap
        let pad = Self.groupInnerPad
        var layout = WorkspaceStripLayout()
        layout.pillX.reserveCapacity(workspaces.count)
        var x: CGFloat = 0
        var i = 0
        while i < workspaces.count {
            guard let gid = workspaces[i].groupID else {
                layout.pillX.append(x)
                x += measureWorkspace(at: i) + gap
                i += 1
                continue
            }
            var end = i
            while end < workspaces.count, workspaces[end].groupID == gid { end += 1 }
            let first = workspaces[i]
            let collapsed = first.groupCollapsed
            let name = first.groupName ?? ""
            let trayMinX = x
            x += pad
            let chipX = x
            let chipW = chipWidth(name: name, collapsed: collapsed, count: end - i)
            x += chipW + pad
            var hiddenActivity = false
            for k in i..<end {
                layout.pillX.append(x)
                // A collapsed group still shows its active member, so the
                // current workspace never disappears from the bar.
                if collapsed && !workspaces[k].isActive {
                    layout.hidden.insert(k)
                    hiddenActivity = hiddenActivity || workspaces[k].hasActivity
                } else {
                    x += measureWorkspace(at: k) + pad
                }
            }
            x += pad
            layout.groups.append(
                WorkspaceStripGroup(
                    id: gid, name: name, collapsed: collapsed, members: i..<end, trayMinX: trayMinX,
                    trayMaxX: x, chipX: chipX, chipWidth: chipW,
                    hiddenActivity: hiddenActivity, color: first.groupColor))
            x += gap
            i = end
        }
        layout.totalWidth = x
        return layout
    }

    /// View-space x of a content x.
    private func viewX(_ contentX: CGFloat) -> CGFloat {
        trafficLightWidth - workspaceScrollOffset + contentX
    }

    /// Frame of the top-bar pill at `index`, in view coordinates; nil when hidden by a collapsed group.
    func workspacePillRect(at index: Int) -> CGRect? {
        let layout = workspaceLayout
        guard index >= 0, index < workspaces.count, !layout.hidden.contains(index) else { return nil }
        let h = Self.workspacePillHeight
        return CGRect(
            x: viewX(layout.pillX[index]), y: (barHeight - h) / 2, width: measureWorkspace(at: index), height: h)
    }

    func groupTrayRect(_ group: WorkspaceStripGroup) -> CGRect {
        let h = Self.groupTrayHeight
        return CGRect(
            x: viewX(group.trayMinX), y: (barHeight - h) / 2, width: group.trayMaxX - group.trayMinX, height: h)
    }

    func groupChipRect(_ group: WorkspaceStripGroup) -> CGRect {
        let h = Self.groupChipHeight
        return CGRect(x: viewX(group.chipX), y: (barHeight - h) / 2, width: group.chipWidth, height: h)
    }

    /// The visible pill at view x; each pill owns the gap after it, so there is
    /// no dead strip between pills.
    func workspaceIndex(atX x: CGFloat) -> Int? {
        workspaces.indices.first { i in
            guard let r = workspacePillRect(at: i) else { return false }
            return x >= r.minX && x < r.maxX + gapAfterWorkspace(i)
        }
    }

    /// Space after pill `i`: the inner padding between members of one group,
    /// the strip gap everywhere else.
    func gapAfterWorkspace(_ i: Int) -> CGFloat {
        let next = workspaces.indices.dropFirst(i + 1).first { !workspaceLayout.hidden.contains($0) }
        guard let gid = workspaces[i].groupID, let next, workspaces[next].groupID == gid else {
            return Self.workspaceGap
        }
        return Self.groupInnerPad
    }

    /// The group whose header chip is under `point`.
    func hitTestGroupChip(at point: NSPoint) -> WorkspaceStripGroup? {
        guard point.x >= trafficLightWidth && point.x < workspaceZoneEnd + zoneGap else { return nil }
        return workspaceLayout.groups.first { groupChipRect($0).insetBy(dx: -2, dy: -3).contains(point) }
    }

    /// Insertion index for a reorder drop at view x: before the first visible
    /// pill whose midpoint lies right of `x`.
    func workspaceInsertionIndex(atX x: CGFloat) -> Int {
        for i in workspaces.indices {
            guard let r = workspacePillRect(at: i) else { continue }
            if x < r.midX { return i }
        }
        return workspaces.count
    }

    /// View x of the insertion indicator for drop index `index`. Inserting before
    /// a group's first member lands outside the group, so the line sits before its tray.
    func insertionIndicatorX(for index: Int) -> CGFloat {
        let layout = workspaceLayout
        if let group = layout.groups.first(where: { $0.members.lowerBound == index }) {
            return viewX(group.trayMinX) - Self.workspaceGap / 2
        }
        if index < workspaces.count {
            // Between two members of a group the gap is the tray's inner padding.
            let gap = workspaces[index].groupID != nil ? Self.groupInnerPad : Self.workspaceGap
            return viewX(layout.pillX[index]) - gap / 2
        }
        return viewX(layout.totalWidth) - Self.workspaceGap / 2
    }

    /// Resolve what a drag at `point` would do: join a group (chip), stack onto
    /// a pill (middle half of another pill), or reorder.
    func updateWorkspaceDropTarget(at point: NSPoint) {
        var insert: Int?
        var stack: Int?
        var group: String?
        if let src = dragSourceIndex {
            let srcGroup = workspaces[src].groupID
            if let chip = hitTestGroupChip(at: point) {
                if chip.id != srcGroup { group = chip.id }
            } else if let target = stackTarget(at: point, source: src) {
                stack = target
            } else {
                insert = validWorkspaceDropIndex(raw: workspaceInsertionIndex(atX: point.x))
            }
        }
        guard insert != dropTargetIndex || stack != dropStackIndex || group != dropGroupID else { return }
        dropTargetIndex = insert
        dropStackIndex = stack
        dropGroupID = group
        needsDisplay = true
    }

    /// Another, unpinned pill whose middle half holds `point` and isn't already
    /// in the dragged workspace's group.
    private func stackTarget(at point: NSPoint, source: Int) -> Int? {
        for i in workspaces.indices where i != source {
            guard let r = workspacePillRect(at: i), r.insetBy(dx: r.width / 4, dy: -4).contains(point) else { continue }
            let target = workspaces[i]
            if target.isPinned { return nil }
            if let gid = target.groupID, gid == workspaces[source].groupID { return nil }
            return i
        }
        return nil
    }

    func validWorkspaceDropIndex(raw: Int) -> Int? {
        guard let src = dragSourceIndex else { return nil }
        if raw == src || raw == src + 1 { return nil }
        let lo = min(src, raw)
        let hi = max(src, raw)
        for i in lo..<hi where i != src {
            if workspaces[i].isPinned { return nil }
        }
        return raw
    }

    // MARK: Drawing

    /// Trays and header chips, drawn under the pills.
    func drawWorkspaceGroups(_ ctx: CGContext, theme: TerminalTheme) {
        for group in workspaceLayout.groups {
            let tray = groupTrayRect(group)
            let highlighted =
                dropGroupID == group.id
                || dropStackIndex.map { group.members.contains($0) } == true
            // A dragged group stays as a faint placeholder, like a dragged pill.
            let lifted = isDragging && draggedGroupID == group.id
            ctx.saveGState()
            defer { ctx.restoreGState() }
            if lifted { ctx.setAlpha(0.3) }
            WorkspacePillStyle.drawGroupTray(
                ctx, rect: tray, color: group.color, highlighted: highlighted, theme: theme)

            let chip = groupChipRect(group)
            if hoveredGroupID == group.id {
                WorkspacePillStyle.fillGroupHeaderHover(ctx, rect: chip, theme: theme)
            }
            drawGroupChipContent(ctx, group, in: chip, theme: theme)
        }
    }

    private func drawGroupChipContent(
        _ ctx: CGContext, _ group: WorkspaceStripGroup, in chip: CGRect, theme: TerminalTheme
    ) {
        let color = WorkspacePillStyle.groupTint(
            color: group.color, hovered: hoveredGroupID == group.id, theme: theme)
        var x = chip.minX + Self.groupChipPadX
        let chevronSize = Self.groupChevronSize
        WorkspacePillStyle.drawGroupChevron(
            collapsed: group.collapsed,
            in: NSRect(x: x, y: chip.midY - chevronSize / 2, width: chevronSize, height: chevronSize), color: color)
        x += chevronSize + Self.groupChipGap

        let countWidth =
            group.collapsed
            ? WorkspacePillStyle.groupCountBadgeWidth(group.members.count, font: Self.groupCountFont) : 0

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.groupChipFont, .foregroundColor: color, .paragraphStyle: para
        ]
        let nameH = (group.name as NSString).size(withAttributes: nameAttrs).height
        let badgeInset = Self.groupBadgeInset
        let nameW = max(
            0, chip.maxX - (countWidth > 0 ? badgeInset + countWidth + Self.groupChipGap : Self.groupChipPadX) - x)
        (group.name as NSString).draw(
            in: NSRect(x: x, y: chip.midY - nameH / 2, width: nameW, height: nameH), withAttributes: nameAttrs)

        guard group.collapsed else { return }
        WorkspacePillStyle.drawGroupCountBadge(
            ctx, count: group.members.count, center: CGPoint(x: chip.maxX - badgeInset - countWidth / 2, y: chip.midY),
            height: Self.groupCountHeight, font: Self.groupCountFont, hiddenActivity: group.hiddenActivity,
            theme: theme,
            tint: group.color)
    }

    // MARK: Dragging a whole group

    /// Click on a chip toggles the group; dragging it moves the whole group
    /// within the bar or, released outside the window, into another window.
    func handleGroupChipMouseDown(startPoint: NSPoint, group: WorkspaceStripGroup) {
        guard let eventWindow = window else { return }
        var didStartDrag = false
        while true {
            guard let next = eventWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp {
                if !didStartDrag {
                    delegate?.toolbar(self, toggleGroup: group.id)
                } else if let point = WorkspaceBarView.screenPointOutsideWindow(next) {
                    delegate?.toolbar(self, dropGroup: group.id, atScreenPoint: point)
                } else if let dest = dropTargetIndex {
                    delegate?.toolbar(self, moveGroup: group.id, to: dest)
                }
                break
            }
            if !didStartDrag {
                let p = convert(next.locationInWindow, from: nil)
                guard hypot(p.x - startPoint.x, p.y - startPoint.y) > 3 else { continue }
                didStartDrag = true
                isDragging = true
                draggedGroupID = group.id
                startGroupGhost(group, event: next)
            }
            ghostWindow?.move(toCenter: DragGhostWindow.screenPoint(of: next))
            let outside = WorkspaceBarView.screenPointOutsideWindow(next)
            let dest: Int? =
                outside != nil
                ? nil
                : WorkspaceGroupDrop.insertionIndex(
                    raw: workspaceInsertionIndex(atX: convert(next.locationInWindow, from: nil).x),
                    moving: group.members, groups: workspaceLayout.groups.map(\.members),
                    firstUnpinned: workspaces.firstIndex { !$0.isPinned } ?? workspaces.count)
            if dest != dropTargetIndex {
                dropTargetIndex = dest
                needsDisplay = true
            }
            delegate?.toolbar(self, workspaceDragMovedOutsideTo: outside)
        }
        if didStartDrag {
            delegate?.toolbar(self, workspaceDragMovedOutsideTo: nil)
            draggedGroupID = nil
            cleanupWorkspaceDrag()
        }
        mouseDownLocation = nil
    }

    private func startGroupGhost(_ group: WorkspaceStripGroup, event: NSEvent) {
        guard let window else { return }
        let rect = groupTrayRect(group)
        let ghost = WorkspaceDragGhostView(
            size: rect.size, label: group.name, font: Self.groupChipFont, centered: false, wsColor: group.color,
            active: false)
        ghostWindow = DragGhostWindow(
            content: ghost, sourceFrame: window.convertToScreen(convert(rect, to: nil)),
            cursor: DragGhostWindow.screenPoint(of: event), alpha: 0.95)
        hoveredWorkspaceIndex = -1
        hoveredGroupID = nil
        needsDisplay = true
    }

    /// Accent ring around a pill the drag would stack onto (ungrouped target;
    /// a grouped target highlights its whole tray instead).
    func drawStackHighlight(_ ctx: CGContext, theme: TerminalTheme) {
        guard let idx = dropStackIndex, workspaces.indices.contains(idx), workspaces[idx].groupID == nil,
            let r = workspacePillRect(at: idx)
        else { return }
        WorkspacePillStyle.strokeDropRing(ctx, around: r, theme: theme)
    }
}

/// Where a dragged group may land, shared by the top bar and the side strip.
enum WorkspaceGroupDrop {
    /// Snap raw insertion index `raw` to a group boundary and reject no-op
    /// drops. `moving` is the dragged group's member range, `groups` every
    /// group's range, `firstUnpinned` the first index past the pinned section.
    static func insertionIndex(raw: Int, moving: Range<Int>, groups: [Range<Int>], firstUnpinned: Int) -> Int? {
        var index = max(raw, firstUnpinned)
        // Never split another group: move to its nearer edge.
        if let other = groups.first(where: { $0 != moving && $0.lowerBound < index && index < $0.upperBound }) {
            index = index - other.lowerBound <= other.upperBound - index ? other.lowerBound : other.upperBound
        }
        if index >= moving.lowerBound && index <= moving.upperBound { return nil }
        return index
    }
}
