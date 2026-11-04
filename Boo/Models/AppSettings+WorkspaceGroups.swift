import Cocoa

extension AppSettings {
    // MARK: - Workspace groups

    var workspaceGroups: [WorkspaceGroup] {
        get {
            let raw = UserDefaults.standard.array(forKey: K.workspaceGroups) as? [[String: Any]] ?? []
            return raw.compactMap(WorkspaceGroup.init(dictionary:))
        }
        set {
            // Drop groups that lost their last member: an empty group has nothing to show.
            let kept = newValue.filter { !$0.members.isEmpty }
            set(kept.map(\.dictionary), forKey: K.workspaceGroups, topic: .workspaceGroups)
        }
    }

    /// The group a workspace (by id string) belongs to, if any.
    func workspaceGroup(forMember member: String) -> WorkspaceGroup? {
        workspaceGroups.group(forMember: member)
    }

    func workspaceGroup(id: String) -> WorkspaceGroup? {
        workspaceGroups.first { $0.id == id }
    }

    /// Read, mutate and write back the group list in one step.
    /// Applies `body` and saves only when it changed something, so callers need
    /// no "already like that" guard of their own.
    private func updateWorkspaceGroups(_ body: (inout [WorkspaceGroup]) -> Void) {
        let current = workspaceGroups
        var groups = current
        body(&groups)
        if groups != current { workspaceGroups = groups }
    }

    /// Put a workspace into the group `id`, or into no group when nil.
    /// A workspace belongs to at most one group.
    func assignWorkspace(member: String, toGroup id: String?) {
        updateWorkspaceGroups { groups in
            for i in groups.indices { groups[i].members.removeAll { $0 == member } }
            if let id, let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i].members.append(member)
            }
        }
    }

    /// Drop closed workspaces from their groups (a group left empty goes too).
    func removeWorkspacesFromGroups(_ members: Set<String>) {
        updateWorkspaceGroups { groups in
            for i in groups.indices { groups[i].members.removeAll { members.contains($0) } }
        }
    }

    /// Create a group holding `members` (moved out of any group they were in) and
    /// return its id; nil for a blank name or no members.
    @discardableResult
    func createWorkspaceGroup(named name: String, with members: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.isEmpty else { return nil }
        let group = WorkspaceGroup(name: trimmed, members: members)
        updateWorkspaceGroups { groups in
            for i in groups.indices { groups[i].members.removeAll { members.contains($0) } }
            groups.append(group)
        }
        return group.id
    }

    /// "Group", "Group 2", … — the first default name no existing group uses.
    func nextWorkspaceGroupName() -> String {
        let taken = Set(workspaceGroups.map(\.name))
        func name(_ n: Int) -> String { n == 1 ? "Group" : "Group \(n)" }
        var n = 1
        while taken.contains(name(n)) { n += 1 }
        return name(n)
    }

    func renameWorkspaceGroup(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateWorkspaceGroups { groups in
            if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].name = trimmed }
        }
    }

    func setWorkspaceGroupCollapsed(id: String, _ collapsed: Bool) {
        guard let group = workspaceGroup(id: id), group.isCollapsed != collapsed else { return }
        updateWorkspaceGroups { groups in
            if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].isCollapsed = collapsed }
        }
    }

    /// Picking a preset clears any custom color.
    func setWorkspaceGroupColor(id: String, _ color: WorkspaceColor) {
        updateWorkspaceGroups { groups in
            guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[i].color = color
            groups[i].customColorHex = nil
        }
    }

    func setWorkspaceGroupCustomColor(id: String, _ color: NSColor) {
        let hex = color.hexString
        updateWorkspaceGroups { groups in
            if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].customColorHex = hex }
        }
    }

    /// Remove the group; its workspaces stay open, just ungrouped.
    func deleteWorkspaceGroup(id: String) {
        updateWorkspaceGroups { $0.removeAll { $0.id == id } }
    }

    /// When true, a workspace created from the + button or menu opens its
    /// name/color editor right away.
    var openWorkspaceEditorOnCreate: Bool {
        get { bool(K.openWorkspaceEditorOnCreate, default: true) }
        set { set(newValue, forKey: K.openWorkspaceEditorOnCreate, topic: .layout) }
    }

    /// When true, a new tab group opens its name/color editor right away.
    var openGroupEditorOnCreate: Bool {
        get { bool(K.openGroupEditorOnCreate, default: true) }
        set { set(newValue, forKey: K.openGroupEditorOnCreate, topic: .layout) }
    }

    /// When true, a new tab opened from a grouped tab joins that tab's group.
    var newTabsJoinActiveGroup: Bool {
        get { bool(K.newTabsJoinActiveGroup, default: true) }
        set { set(newValue, forKey: K.newTabsJoinActiveGroup, topic: .layout) }
    }
}
