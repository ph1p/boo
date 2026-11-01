import Cocoa

// MARK: - Workspace groups
//
// Groups live in `AppSettings` (app-wide, keyed by workspace folder path). This
// window only keeps its own workspace order tidy: members of a group sit next to
// each other so the bars can draw one header per group.

extension MainWindowController {
    /// "Group" submenu for a workspace's context menu, shared by the top bar and the side strip.
    func workspaceGroupMenuItems(forWorkspaceAt index: Int) -> [NSMenuItem] {
        guard index >= 0, index < appState.workspaces.count else { return [] }
        let ws = appState.workspaces[index]
        let wsID = ws.id
        let path = ws.folderPath
        let settings = AppSettings.shared
        let current = settings.workspaceGroup(forPath: path)

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

    /// Context menu for a group header in the side strip.
    func workspaceGroupHeaderMenuItems(groupID: String) -> [NSMenuItem] {
        guard let group = AppSettings.shared.workspaceGroup(id: groupID) else { return [] }
        return [
            ClosureMenuItem(title: group.isCollapsed ? "Expand" : "Collapse") { [weak self] in
                self?.toggleWorkspaceGroup(groupID)
            },
            ClosureMenuItem(title: "Rename Group…") { [weak self] in
                self?.promptRenameWorkspaceGroup(groupID)
            },
            .separator(),
            ClosureMenuItem(title: "Ungroup") {
                AppSettings.shared.deleteWorkspaceGroup(id: groupID)
            }
        ]
    }

    func toggleWorkspaceGroup(_ groupID: String) {
        guard let group = AppSettings.shared.workspaceGroup(id: groupID) else { return }
        AppSettings.shared.setWorkspaceGroupCollapsed(id: groupID, !group.isCollapsed)
    }

    /// Move a workspace into a group (nil = no group). The settings change fans
    /// out to every window, which re-clusters on its next toolbar refresh.
    func assignWorkspace(_ wsID: UUID, toGroup groupID: String?) {
        guard let ws = appState.workspaces.first(where: { $0.id == wsID }) else { return }
        AppSettings.shared.assignWorkspace(path: ws.folderPath, toGroup: groupID)
    }

    /// Drag reorder from either bar: move, then let the drop position decide group membership.
    func reorderWorkspace(from source: Int, to destination: Int) {
        guard appState.workspaces.indices.contains(source) else { return }
        let movedID = appState.workspaces[source].id
        appState.moveWorkspace(from: source, to: destination)
        syncWorkspaceGroupAfterMove(movedID)
        refreshToolbar()
        saveSession()
    }

    /// Group id per workspace index in this window; pinned workspaces count as ungrouped.
    private func workspaceGroupIDs() -> [String?] {
        let byPath = AppSettings.shared.workspaceGroups.groupIDByPath
        return appState.workspaces.map { $0.isPinned ? nil : byPath[$0.folderPath] }
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
        let byPath = AppSettings.shared.workspaceGroups.groupIDByPath
        let ids = appState.workspaces.map { byPath[$0.folderPath] }
        let groupOf: (Int) -> String? = { ids.indices.contains($0) ? ids[$0] : nil }
        let own = groupOf(i)
        let above = groupOf(i - 1)
        let below = groupOf(i + 1)
        let path = appState.workspaces[i].folderPath
        if let above, above == below, above != own {
            AppSettings.shared.assignWorkspace(path: path, toGroup: above)
        } else if let own, above != own, below != own {
            // Only leave when the rest of the group is actually open here; otherwise
            // there is nothing to stay next to.
            let othersHere = ids.indices.contains { $0 != i && ids[$0] == own }
            if othersHere { AppSettings.shared.assignWorkspace(path: path, toGroup: nil) }
        }
    }

    private func promptNewWorkspaceGroup(forWorkspace wsID: UUID) {
        guard let ws = appState.workspaces.first(where: { $0.id == wsID }) else { return }
        promptForText(title: "New Workspace Group", placeholder: "Group name", confirm: "Create") { name in
            AppSettings.shared.createWorkspaceGroup(named: name, with: ws.folderPath)
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
