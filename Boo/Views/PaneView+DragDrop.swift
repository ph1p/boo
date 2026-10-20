import Cocoa
import SwiftUI

extension PaneView {

    // MARK: - Tab Hit Testing

    func tabIndex(at point: NSPoint) -> Int? {
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .vertical { return verticalTabIndex(at: point) }
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
        guard showTabClose, !pane.isTabHidden(at: idx) else { return false }
        let mode = AppSettings.shared.tabOverflowMode
        if mode == .vertical { return isOverVerticalCloseButton(point: point, tabIndex: idx) }
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
        if isVerticalTabs, isInTabBar(point) {
            let maxScroll = verticalScrollMaxOffset()
            guard maxScroll > 0 else { return }
            tabScrollOffset = min(max(0, tabScrollOffset - event.scrollingDeltaY), maxScroll)
            needsDisplay = true
            return
        }
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
        guard !pane.tabs.isEmpty, isInTabBar(point) else { return }

        if let idx = tabIndex(at: point) {
            if let groupID = groupChipHit(at: point, tabIndex: idx) {
                // Click toggles collapse, drag moves the group — decided on mouseUp.
                groupPressID = groupID
                groupPressPoint = point
                groupDropIndex = nil
            } else if isOverCloseButton(point: point, tabIndex: idx) {
                paneDelegate?.paneView(self, didRequestCloseTab: idx, paneID: paneID)
            } else if event.modifierFlags.contains(.command) {
                toggleTabSelection(idx)
            } else {
                clearTabSelection()
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
        let point = convert(event.locationInWindow, from: nil)
        if groupPressID != nil, let start = groupPressPoint {
            guard groupDropIndex != nil || hypot(point.x - start.x, point.y - start.y) > dragThreshold else { return }
            autoscrollTabBar(local: point)
            groupDropIndex = tabInsertionIndex(at: point)
            needsDisplay = true
            return
        }
        guard let dragIdx = dragTabIndex, let startPt = dragStartPoint else { return }

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
        if let groupID = groupPressID {
            if let index = groupDropIndex {
                pane.moveGroup(groupID, to: index)
                groupsChanged()
            } else {
                toggleGroupCollapsed(groupID)
            }
        } else if let idx = dragTabIndex {
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
        groupPressID = nil
        groupPressPoint = nil
        groupDropIndex = nil
        dragTabIndex = nil
        dragStartPoint = nil
        dragCurrentX = nil
        needsDisplay = true
    }

    // MARK: - Multi-select

    /// ⌘-click adds or removes a tab from the selection; the first pick also
    /// takes in the active tab, so ⌘-clicking one other tab selects two.
    private func toggleTabSelection(_ index: Int) {
        let id = pane.tabs[index].id
        if selectedTabIDs.isEmpty, let active = pane.activeTab?.id, active != id {
            selectedTabIDs.insert(active)
        }
        if selectedTabIDs.remove(id) == nil { selectedTabIDs.insert(id) }
        needsDisplay = true
    }

    func clearTabSelection() {
        guard !selectedTabIDs.isEmpty else { return }
        selectedTabIDs = []
        needsDisplay = true
    }

    /// Indices of the selected tabs still in this pane, in tab order.
    private var selectedTabIndices: [Int] {
        pane.tabs.indices.filter { selectedTabIDs.contains(pane.tabs[$0].id) }
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInTabBar(point), let idx = tabIndex(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        if let groupID = groupChipHit(at: point, tabIndex: idx) {
            showGroupContextMenu(groupID, event: event)
        } else {
            showTabContextMenu(at: idx, event: event)
        }
    }

    private func showTabContextMenu(at index: Int, event: NSEvent) {
        if !selectedTabIDs.contains(pane.tabs[index].id) { clearTabSelection() }
        let menu = NSMenu()

        // Close tab
        let isLastTabInWorkspace = isOnlyTabInWorkspace()
        let closeTitle = isLastTabInWorkspace ? "Close Workspace" : "Close Tab"
        let closeItem = NSMenuItem(title: closeTitle, action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = index
        menu.addItem(closeItem)

        addGroupItems(to: menu, tabIndex: index)

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

    // MARK: - Tab Group Actions

    /// What a group menu item acts on: the tabs (by ID, so a menu held open
    /// across tab changes can't hit the wrong tab) and/or the group.
    private struct GroupMenuAction {
        var tabIDs: [UUID] = []
        var groupID: UUID?
        var color: WorkspaceColor?
        var workspaceIndex: Int?
    }

    private func groupMenuItem(_ title: String, _ action: Selector, _ payload: GroupMenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    /// Small filled circle in the group's color, for menu items naming a group.
    private func groupSwatch(_ group: TabGroup) -> NSImage {
        let color = groupTint(group, theme: AppSettings.shared.theme)
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func groupMenuTitle(_ group: TabGroup) -> String {
        group.name.isEmpty ? "Unnamed Group" : group.name
    }

    /// "New Group" plus one item per group other than `excluded`.
    private func addToGroupSubmenu(tabIDs: [UUID], excluding excluded: UUID?) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(groupMenuItem("New Group", #selector(contextNewGroup(_:)), GroupMenuAction(tabIDs: tabIDs)))
        let others = pane.groups.filter { $0.id != excluded }
        if !others.isEmpty { sub.addItem(.separator()) }
        for group in others {
            let item = groupMenuItem(
                groupMenuTitle(group), #selector(contextAddToGroup(_:)),
                GroupMenuAction(tabIDs: tabIDs, groupID: group.id))
            item.image = groupSwatch(group)
            sub.addItem(item)
        }
        return sub
    }

    private func addGroupItems(to menu: NSMenu, tabIndex index: Int) {
        menu.addItem(.separator())
        let tab = pane.tabs[index]
        let selection = selectedTabIndices
        if selection.count > 1, selection.contains(index) {
            let ids = selection.map { pane.tabs[$0].id }
            menu.addItem(
                groupMenuItem(
                    "Add \(ids.count) Tabs to New Group", #selector(contextNewGroup(_:)),
                    GroupMenuAction(tabIDs: ids)))
            if !pane.groups.isEmpty {
                let item = NSMenuItem(title: "Add \(ids.count) Tabs to Group", action: nil, keyEquivalent: "")
                item.submenu = addToGroupSubmenu(tabIDs: ids, excluding: nil)
                menu.addItem(item)
            }
            return
        }
        guard let group = pane.group(id: tab.groupID) else {
            if pane.groups.isEmpty {
                menu.addItem(
                    groupMenuItem(
                        "Add Tab to New Group", #selector(contextNewGroup(_:)), GroupMenuAction(tabIDs: [tab.id])))
            } else {
                let item = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
                item.submenu = addToGroupSubmenu(tabIDs: [tab.id], excluding: nil)
                menu.addItem(item)
            }
            return
        }
        let target = GroupMenuAction(tabIDs: [tab.id], groupID: group.id)
        menu.addItem(groupMenuItem("Edit Group…", #selector(contextEditGroup(_:)), target))
        let move = NSMenuItem(title: "Move Tab to Group", action: nil, keyEquivalent: "")
        move.submenu = addToGroupSubmenu(tabIDs: [tab.id], excluding: group.id)
        menu.addItem(move)
        menu.addItem(groupMenuItem("Remove from Group", #selector(contextRemoveFromGroup(_:)), target))
    }

    /// Menu for a group chip / header: everything that acts on the whole group.
    private func showGroupContextMenu(_ id: UUID, event: NSEvent) {
        guard let group = pane.group(id: id) else { return }
        clearTabSelection()
        let target = GroupMenuAction(groupID: id)
        let menu = NSMenu()
        menu.addItem(groupMenuItem("Edit Group…", #selector(contextEditGroup(_:)), target))
        menu.addItem(groupMenuItem("New Tab in Group", #selector(contextNewTabInGroup(_:)), target))
        menu.addItem(
            groupMenuItem(
                group.isCollapsed ? "Expand Group" : "Collapse Group", #selector(contextToggleGroup(_:)), target))

        menu.addItem(.separator())
        let split = groupMenuItem("Move Group to New Split", #selector(contextSplitGroup(_:)), target)
        // A group holding every tab would leave an empty pane behind.
        if !pane.tabs.contains(where: { $0.groupID != id }) {
            split.action = nil
        }
        menu.addItem(split)
        if let workspaces = paneDelegate?.paneViewWorkspaceNames(self), !workspaces.isEmpty {
            let sub = NSMenu()
            for ws in workspaces {
                var payload = target
                payload.workspaceIndex = ws.index
                sub.addItem(groupMenuItem(ws.name, #selector(contextMoveGroupToWorkspace(_:)), payload))
            }
            let item = NSMenuItem(title: "Move Group to Workspace", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(groupMenuItem("Ungroup", #selector(contextUngroup(_:)), target))
        menu.addItem(groupMenuItem("Close Group", #selector(contextCloseGroup(_:)), target))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Collapses or expands a group. Collapsing moves off a tab inside it
    /// first; a group holding every tab of the pane stays open.
    func toggleGroupCollapsed(_ id: UUID) {
        guard let group = pane.group(id: id) else { return }
        if !group.isCollapsed, let active = pane.activeTab, active.groupID == id {
            guard let outside = pane.outsideTabIndex(of: id) else {
                NSSound.beep()
                return
            }
            activateTab(outside)
        }
        pane.updateGroup(id) { $0.isCollapsed.toggle() }
        groupsChanged()
    }

    func groupsChanged() {
        hoveredTabIndex = -1
        isGroupChipHovered = false
        isCloseButtonHovered = false
        selectedTabIDs.formIntersection(pane.tabs.map(\.id))
        if let popover = groupEditorPopover, popover.isShown,
            let id = popover.contentViewController?.representedObject as? UUID, pane.group(id: id) == nil
        {
            popover.close()
        }
        needsDisplay = true
        WindowManager.shared.saveSessionSoon()
    }

    private func groupAction(_ sender: NSMenuItem) -> GroupMenuAction? {
        sender.representedObject as? GroupMenuAction
    }

    private func tabIndices(of ids: [UUID]) -> [Int] {
        ids.compactMap { id in pane.tabs.firstIndex { $0.id == id } }
    }

    @objc private func contextNewGroup(_ sender: NSMenuItem) {
        guard let action = groupAction(sender),
            let gid = pane.createGroup(withTabsAt: tabIndices(of: action.tabIDs))
        else { return }
        selectedTabIDs = []
        groupsChanged()
        if AppSettings.shared.openGroupEditorOnCreate { showGroupEditor(gid) }
    }

    @objc private func contextAddToGroup(_ sender: NSMenuItem) {
        guard let action = groupAction(sender), let gid = action.groupID, pane.group(id: gid) != nil else { return }
        for id in action.tabIDs {
            guard let index = pane.tabs.firstIndex(where: { $0.id == id }) else { continue }
            pane.addTab(at: index, toGroup: gid)
        }
        selectedTabIDs = []
        groupsChanged()
    }

    @objc private func contextEditGroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        showGroupEditor(gid)
    }

    @objc private func contextNewTabInGroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        newTab(inGroup: gid)
    }

    @objc private func contextToggleGroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        toggleGroupCollapsed(gid)
    }

    @objc private func contextRemoveFromGroup(_ sender: NSMenuItem) {
        guard let id = groupAction(sender)?.tabIDs.first, let index = pane.tabs.firstIndex(where: { $0.id == id })
        else { return }
        pane.removeTabFromGroup(at: index)
        groupsChanged()
    }

    @objc private func contextUngroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        pane.ungroup(gid)
        groupsChanged()
    }

    @objc private func contextCloseGroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        paneDelegate?.paneView(self, didRequestCloseGroup: gid, paneID: paneID)
    }

    @objc private func contextSplitGroup(_ sender: NSMenuItem) {
        guard let gid = groupAction(sender)?.groupID else { return }
        paneDelegate?.paneView(self, didRequestSplitGroup: gid, paneID: paneID)
    }

    @objc private func contextMoveGroupToWorkspace(_ sender: NSMenuItem) {
        guard let action = groupAction(sender), let gid = action.groupID, let ws = action.workspaceIndex else { return }
        paneDelegate?.paneView(self, didRequestMoveGroup: gid, toWorkspaceAt: ws, paneID: paneID)
    }

    /// Opens a terminal in the group's folder (its first tab's) and adds it to the group.
    func newTab(inGroup id: UUID) {
        let cwd = pane.tabs.first { $0.groupID == id }?.workingDirectory ?? pane.activeTab?.workingDirectory ?? "~"
        addNewTab(workingDirectory: cwd, group: id)
    }

    // MARK: - Group Editor

    /// Inline editor for a group's name and color, anchored on its chip.
    func showGroupEditor(_ id: UUID) {
        groupEditorPopover?.close()
        guard let group = pane.group(id: id) else { return }
        // The chip may be scrolled out of view; anchor on the visible bar then.
        guard var anchor = groupChipRect(for: id) else { return }
        if !visibleRect.intersects(anchor) {
            anchor = NSRect(x: visibleRect.midX, y: anchor.minY, width: 1, height: anchor.height)
        }

        weak var popoverRef: NSPopover?
        let close: () -> Void = { popoverRef?.close() }
        let editor = InlineEditorView(
            name: group.name, color: group.color, hasCustomColor: false,
            placeholder: "Name this group",
            onRename: { [weak self] name in
                self?.pane.updateGroup(id) { $0.name = name.trimmingCharacters(in: .whitespaces) }
                self?.groupsChanged()
            },
            onColor: { [weak self] color in
                self?.pane.updateGroup(id) { $0.color = color }
                self?.groupsChanged()
            },
            actions: [
                InlineEditorAction(title: "New Tab in Group", symbol: "plus") { [weak self] in
                    close()
                    self?.newTab(inGroup: id)
                },
                InlineEditorAction(title: "Ungroup", symbol: "rectangle.dashed") { [weak self] in
                    close()
                    self?.pane.ungroup(id)
                    self?.groupsChanged()
                },
                InlineEditorAction(title: "Close Group", symbol: "xmark", isDestructive: true) { [weak self] in
                    close()
                    guard let self else { return }
                    self.paneDelegate?.paneView(self, didRequestCloseGroup: id, paneID: self.paneID)
                }
            ],
            onDone: close)
        let popover = makeInlineEditorPopover(editor, tag: id)
        popoverRef = popover
        groupEditorPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: isVerticalTabs ? .maxX : .maxY)
    }

    @objc private func contextNewTab(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType else { return }
        addNewTab(contentType: type, workingDirectory: pane.activeTab?.workingDirectory ?? "~", group: activeGroupID)
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
    /// `local` is the cursor in pane-local coords. Scrolls when near edges.
    func autoscrollTabBar(local: NSPoint) {
        if isVerticalTabs { return autoscrollVerticalTabs(localY: local.y) }
        let localX = local.x
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
        if mode == .vertical { return NSPoint(x: Self.tabBarSideInset, y: verticalInsertionY(at: index)) }
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
        if isVerticalTabs { return verticalInsertionIndex(at: point) }
        if AppSettings.shared.tabOverflowMode == .wrap {
            let layouts = wrapLayout()
            // Determine which row the point is on (rows start below the bar's top inset)
            let row = max(0, Int((point.y - Self.tabBarSideInset) / singleRowTabHeight))
            let rowY = Self.tabBarSideInset + CGFloat(row) * singleRowTabHeight
            // Filter to tabs on this row, find insertion point by x
            for i in 0..<layouts.count {
                let lay = layouts[i]
                if lay.y == rowY && lay.width > 0 && point.x < lay.x + lay.width / 2 { return i }
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
                if w > 0 && adjusted < cx + w / 2 { return i }
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
