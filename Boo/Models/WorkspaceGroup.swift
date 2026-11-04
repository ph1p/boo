import Cocoa

/// A named, collapsible group of workspaces. App-wide: every window shows the
/// same groups. Members are workspace ids (`Workspace.id.uuidString`): the id is
/// saved with the session and survives moving a workspace between windows, and
/// unlike the folder path it tells apart two workspaces open on the same folder.
struct WorkspaceGroup: Equatable {
    var id = UUID().uuidString
    var name: String
    var isCollapsed = false
    var members: [String] = []
    /// Tint of the group's tray and header; `.none` keeps the neutral chrome.
    var color: WorkspaceColor = .none
    /// User-picked "#RRGGBB" from the color panel; overrides `color` when set.
    var customColorHex: String?

    /// Custom color first, then the preset, nil for neutral chrome.
    var resolvedColor: NSColor? { customColorHex.flatMap(NSColor.init(hex:)) ?? color.nsColor }
    /// Chrome colour: a custom colour as picked, a preset from the theme palette.
    func resolvedColor(theme: TerminalTheme) -> NSColor? {
        customColorHex.flatMap(NSColor.init(hex:)) ?? color.themed(theme)
    }

    /// Plist/JSON-safe form, so the value round-trips through UserDefaults and settings.json.
    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "id": id, "name": name, "collapsed": isCollapsed, "members": members, "color": color.rawValue
        ]
        if let customColorHex { d["customColor"] = customColorHex }
        return d
    }
}

extension WorkspaceGroup {
    init?(dictionary d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        self.init(
            id: id, name: name, isCollapsed: d["collapsed"] as? Bool ?? false,
            members: d["members"] as? [String] ?? [],
            color: (d["color"] as? String).flatMap(WorkspaceColor.init(rawValue:)) ?? .none,
            customColorHex: (d["customColor"] as? String).flatMap { NSColor(hex: $0) != nil ? $0 : nil })
    }
}

extension [WorkspaceGroup] {
    /// The group a workspace belongs to, if any.
    func group(forMember member: String) -> WorkspaceGroup? {
        first { $0.members.contains(member) }
    }

    /// Workspace id -> group id, for lookups inside loops.
    var groupIDByMember: [String: String] {
        var map: [String: String] = [:]
        for group in self { for member in group.members where map[member] == nil { map[member] = group.id } }
        return map
    }
}
