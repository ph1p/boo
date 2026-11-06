import Cocoa

// MARK: - Workspace groups
//
// Groups live in `AppSettings` (app-wide, keyed by workspace id). This window only
// keeps its own workspace order tidy: members of a group sit next to each other so
// the bars can draw one header per group.

extension MainWindowController {
    /// "Group" submenu for a workspace's context menu, shared by the top bar and the side strip.
    func workspaceGroupMenuItems(forWorkspaceAt index: Int) -> [NSMenuItem] {
        guard index >= 0, index < appState.workspaces.count, appState.workspaces[index].tmuxWindowID == nil
        else { return [] }
        let ws = appState.workspaces[index]
        let wsID = ws.id
        let settings = AppSettings.shared
        let current = settings.workspaceGroup(forMember: wsID.uuidString)

        let menu = NSMenu()
        menu.addItem(
            ClosureMenuItem(title: "New Group…") { [weak self] in
                self?.promptNewWorkspaceGroup(forWorkspace: wsID)
            })
        let groups = settings.workspaceGroups
        if !groups.isEmpty { menu.addItem(.separator()) }
        for group in groups {
            let item = ClosureMenuItem(title: group.name) { [weak self] in
                self?.assignWorkspace(wsID, toGroup: group.id)
            }
            item.state = group.id == current?.id ? .on : .off
            menu.addItem(item)
        }
        if current != nil {
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem(title: "Remove from Group") { [weak self] in
                    self?.assignWorkspace(wsID, toGroup: nil)
                })
        }

        let parent = NSMenuItem(title: current.map { "Group: \($0.name)" } ?? "Group", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return [parent]
    }

    /// Context menu for a group header (top-bar chip or side-strip header).
    func workspaceGroupHeaderMenuItems(groupID: String) -> [NSMenuItem] {
        if let client = Self.tmuxClient(chipID: groupID) { return tmuxChipMenuItems(client) }
        guard let group = AppSettings.shared.workspaceGroup(id: groupID) else { return [] }
        let colorMenu = NSMenu()
        for color in WorkspaceColor.allCases {
            let item = ClosureMenuItem(title: color == .none ? "None" : color.label) {
                AppSettings.shared.setWorkspaceGroupColor(id: groupID, color)
            }
            item.state = group.customColorHex == nil && color == group.color ? .on : .off
            if let swatch = color.nsColor { item.image = Self.colorSwatch(swatch) }
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let custom = ClosureMenuItem(title: "Custom…") {
            ColorPanelRelay.shared.begin(initial: AppSettings.shared.workspaceGroup(id: groupID)?.resolvedColor) {
                AppSettings.shared.setWorkspaceGroupCustomColor(id: groupID, $0)
            }
        }
        if let hex = group.customColorHex, let swatch = NSColor(hex: hex) {
            custom.state = .on
            custom.image = Self.colorSwatch(swatch)
        }
        colorMenu.addItem(custom)
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu

        var items: [NSMenuItem] = [
            ClosureMenuItem(title: group.isCollapsed ? "Expand" : "Collapse") { [weak self] in
                self?.toggleWorkspaceGroup(groupID)
            },
            ClosureMenuItem(title: "Rename Group…") { [weak self] in
                self?.promptRenameWorkspaceGroup(groupID)
            },
            colorItem
        ]
        if canMoveWorkspaceGroupToNewWindow(groupID) {
            items.append(.separator())
            items.append(
                ClosureMenuItem(title: "Move Group to New Window") { [weak self] in
                    self?.moveWorkspaceGroupToNewWindow(groupID)
                })
        }
        items.append(.separator())
        items.append(
            ClosureMenuItem(title: "Ungroup") {
                AppSettings.shared.deleteWorkspaceGroup(id: groupID)
            })
        return items
    }

    private static func colorSwatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    func toggleWorkspaceGroup(_ groupID: String) {
        // A tmux chip opens its session menu: the active window would stay
        // visible anyway, so collapsing a session hides next to nothing.
        if let client = Self.tmuxClient(chipID: groupID) {
            showTmuxChipMenu(client)
            return
        }
        guard let group = AppSettings.shared.workspaceGroup(id: groupID) else { return }
        AppSettings.shared.setWorkspaceGroupCollapsed(id: groupID, !group.isCollapsed)
    }

    /// Move a workspace into a group (nil = no group). The settings change fans
    /// out to every window, which re-clusters on its next toolbar refresh.
    func assignWorkspace(_ wsID: UUID, toGroup groupID: String?) {
        AppSettings.shared.assignWorkspace(member: wsID.uuidString, toGroup: groupID)
    }

    /// Drag-drop of workspace `source` onto the pill at `target`: join the
    /// target's group, or start a new group holding both. The dragged pill lands
    /// right after the target.
    func stackWorkspace(from source: Int, onto target: Int) {
        let workspaces = appState.workspaces
        guard source != target, workspaces.indices.contains(source), workspaces.indices.contains(target),
            workspaces[source].joinsGroups, workspaces[target].joinsGroups
        else { return }
        let moved = workspaces[source].id
        let anchor = workspaces[target].id
        let settings = AppSettings.shared
        if let group = settings.workspaceGroup(forMember: anchor.uuidString) {
            settings.assignWorkspace(member: moved.uuidString, toGroup: group.id)
        } else {
            settings.createWorkspaceGroup(
                named: settings.nextWorkspaceGroupName(), with: [anchor.uuidString, moved.uuidString])
        }
        placeWorkspace(moved, after: anchor)
    }

    /// Drag-drop of workspace `source` onto a group header: join that group at its end.
    func moveWorkspace(at source: Int, intoGroup groupID: String) {
        guard appState.workspaces.indices.contains(source), appState.workspaces[source].joinsGroups,
            let group = AppSettings.shared.workspaceGroup(id: groupID)
        else { return }
        let moved = appState.workspaces[source].id
        let members = Set(group.members)
        let lastMember = appState.workspaces.last { members.contains($0.id.uuidString) && $0.id != moved }
        AppSettings.shared.assignWorkspace(member: moved.uuidString, toGroup: groupID)
        if let lastMember { placeWorkspace(moved, after: lastMember.id) } else { finishGroupChange() }
    }

    /// Move workspace `id` to sit right after `anchor`, then refresh and save.
    private func placeWorkspace(_ id: UUID, after anchor: UUID) {
        if let from = appState.workspaces.firstIndex(where: { $0.id == id }),
            let anchorIndex = appState.workspaces.firstIndex(where: { $0.id == anchor })
        {
            // `moveWorkspace(from:to:)` takes an insertion index in the pre-move list.
            appState.moveWorkspace(from: from, to: anchorIndex + 1)
        }
        finishGroupChange()
    }

    private func finishGroupChange() {
        refreshToolbar()
        saveSession()
    }

    /// Drag reorder from either bar: move, then let the drop position decide group membership.
    func reorderWorkspace(from source: Int, to destination: Int) {
        guard appState.workspaces.indices.contains(source) else { return }
        let movedID = appState.workspaces[source].id
        appState.moveWorkspace(from: source, to: destination)
        // A drop back on its own spot is not a move, so membership stays.
        if appState.workspaces.firstIndex(where: { $0.id == movedID }) != source {
            syncWorkspaceGroupAfterMove(movedID)
        }
        finishGroupChange()
    }

    /// Group id per workspace index in this window; pinned workspaces count as ungrouped.
    private func workspaceGroupIDs() -> [String?] {
        let byMember = AppSettings.shared.workspaceGroups.groupIDByMember
        return appState.workspaces.map { ws in
            if let chip = tmuxChip(for: ws) { return chip.id }
            return ws.isPinned ? nil : byMember[ws.id.uuidString]
        }
    }

    /// Keep each group's members contiguous in this window: later members are
    /// pulled up behind the group's first run. Pinned workspaces stay in the
    /// pinned section and are left alone. Returns whether anything moved.
    @discardableResult
    func clusterWorkspaceGroups() -> Bool {
        var ids = workspaceGroupIDs()
        var changed = false
        var i = 0
        while i < ids.count {
            guard let gid = ids[i] else {
                i += 1
                continue
            }
            var end = i + 1
            while end < ids.count, ids[end] == gid { end += 1 }
            for k in end..<ids.count where ids[k] == gid {
                appState.moveWorkspace(from: k, to: end)
                ids.insert(ids.remove(at: k), at: end)
                end += 1
                changed = true
            }
            i = end
        }
        return changed
    }

    /// After a drag reorder: dropping between two members of a group joins it,
    /// dragging a member away from all of its group leaves it.
    func syncWorkspaceGroupAfterMove(_ wsID: UUID) {
        guard let i = appState.workspaces.firstIndex(where: { $0.id == wsID }) else { return }
        let ids = workspaceGroupIDs()
        let groupOf: (Int) -> String? = { ids.indices.contains($0) ? ids[$0] : nil }
        let own = groupOf(i)
        let above = groupOf(i - 1)
        let below = groupOf(i + 1)
        let member = wsID.uuidString
        // tmux chips are not stored groups: nothing joins or leaves them.
        if [own, above, below].contains(where: { $0?.hasPrefix(Self.tmuxChipPrefix) == true }) { return }
        if let above, above == below, above != own {
            AppSettings.shared.assignWorkspace(member: member, toGroup: above)
        } else if let own, above != own, below != own {
            // Leave the group, unless all its other members live in another
            // window: then there is nothing here to stay next to. A last member
            // leaves too, and the empty group goes away.
            let othersHere = ids.indices.contains { $0 != i && ids[$0] == own }
            let othersAnywhere = AppSettings.shared.workspaceGroup(id: own)?.members.contains { $0 != member } ?? false
            if othersHere || !othersAnywhere { AppSettings.shared.assignWorkspace(member: member, toGroup: nil) }
        }
    }

    // MARK: Moving a whole group

    /// Ids of this window's workspaces in `groupID`, in bar order (pinned ones never count).
    private func workspaceIDs(inGroup groupID: String) -> [UUID] {
        let ids = workspaceGroupIDs()
        return appState.workspaces.indices.filter { ids[$0] == groupID }.map { appState.workspaces[$0].id }
    }

    /// Drag of a group header within the bar: move all members, in order, to
    /// insertion index `destination` (an index into the current list).
    func moveWorkspaceGroup(_ groupID: String, to destination: Int) {
        let members = workspaceIDs(inGroup: groupID)
        guard !members.isEmpty, destination >= 0, destination <= appState.workspaces.count else { return }
        let anchor = destination < appState.workspaces.count ? appState.workspaces[destination].id : nil
        if let anchor, members.contains(anchor) { return }
        // Insert each member right before the anchor (or at the end), which keeps their order.
        for id in members {
            guard let from = appState.workspaces.firstIndex(where: { $0.id == id }) else { continue }
            let to = anchor.flatMap { a in appState.workspaces.firstIndex { $0.id == a } } ?? appState.workspaces.count
            appState.moveWorkspace(from: from, to: to)
        }
        finishGroupChange()
    }

    /// A new window only makes sense when the group leaves something behind.
    func canMoveWorkspaceGroupToNewWindow(_ groupID: String) -> Bool {
        // A tmux session stays with the window that runs its control client.
        guard !groupID.hasPrefix(Self.tmuxChipPrefix) else { return false }
        let count = workspaceIDs(inGroup: groupID).count
        return count > 0 && count < appState.workspaces.count
    }

    func moveWorkspaceGroupToNewWindow(_ groupID: String) {
        guard canMoveWorkspaceGroupToNewWindow(groupID), let frame = window?.frame else { return }
        let (detached, activeIndex) = detachWorkspaceGroup(groupID)
        adoptInNewWindow(detached, activeIndex: activeIndex, at: Self.cascadePoint(from: frame), size: frame.size)
    }

    /// A group header was dropped outside this window: move the whole group into
    /// the window under the cursor, or into a new window there.
    func dropWorkspaceGroup(_ groupID: String, atScreenPoint point: NSPoint) {
        guard !groupID.hasPrefix(Self.tmuxChipPrefix) else { return }
        let manager = WindowManager.shared
        if let target = manager.controller(atScreenPoint: point, excluding: self) {
            let dropIndex = target.workspaceDropIndex(atScreenPoint: point)
            let (detached, activeIndex) = detachWorkspaceGroup(groupID)
            for (k, ws) in detached.enumerated() {
                target.adoptWorkspace(ws, at: dropIndex + k, activate: k == activeIndex)
            }
            target.window?.makeKeyAndOrderFront(nil)
            if appState.workspaces.isEmpty { window?.close() }
        } else {
            guard canMoveWorkspaceGroupToNewWindow(groupID) else { return }
            let size = window?.frame.size
            let (detached, activeIndex) = detachWorkspaceGroup(groupID)
            adoptInNewWindow(detached, activeIndex: activeIndex, at: point, size: size)
        }
    }

    /// Detach every member of `groupID` in bar order. `activeIndex` is the
    /// member to show in the destination: the one active here, else the first.
    private func detachWorkspaceGroup(_ groupID: String) -> (detached: [DetachedWorkspace], activeIndex: Int) {
        let members = workspaceIDs(inGroup: groupID)
        let activeID =
            appState.workspaces.indices.contains(appState.activeWorkspaceIndex)
            ? appState.workspaces[appState.activeWorkspaceIndex].id : nil
        var detached: [DetachedWorkspace] = []
        for id in members {
            guard let i = appState.workspaces.firstIndex(where: { $0.id == id }),
                let ws = detachWorkspace(at: i)
            else { continue }
            detached.append(ws)
        }
        let activeIndex = detached.firstIndex { $0.workspace.id == activeID } ?? 0
        return (detached, activeIndex)
    }

    private func adoptInNewWindow(
        _ detached: [DetachedWorkspace], activeIndex: Int, at point: NSPoint, size: NSSize?
    ) {
        guard let first = detached.first else { return }
        let controller = WindowManager.shared.newWindow(adopting: first, at: point, size: size)
        for ws in detached.dropFirst() {
            controller.adoptWorkspace(ws, activate: false)
        }
        if activeIndex > 0 { controller.activateWorkspace(activeIndex) }
    }

    private func promptNewWorkspaceGroup(forWorkspace wsID: UUID) {
        promptForText(
            title: "New Workspace Group", initial: AppSettings.shared.nextWorkspaceGroupName(),
            placeholder: "Group name", confirm: "Create"
        ) { name in
            AppSettings.shared.createWorkspaceGroup(named: name, with: [wsID.uuidString])
        }
    }

    private func promptRenameWorkspaceGroup(_ groupID: String) {
        guard let group = AppSettings.shared.workspaceGroup(id: groupID) else { return }
        promptForText(
            title: "Rename Group", initial: group.name, placeholder: "Group name", confirm: "Rename"
        ) { name in
            AppSettings.shared.renameWorkspaceGroup(id: groupID, to: name)
        }
    }

    /// One-line text prompt as a sheet on this window. `completion` gets the
    /// trimmed text and is skipped for a blank answer or Cancel.
    func promptForText(
        title: String, informative: String = "", initial: String = "", placeholder: String = "",
        confirm: String, completion: @escaping (String) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = initial
        input.placeholderString = placeholder
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            completion(text)
        }
        alert.window.makeFirstResponder(input)
    }
}
