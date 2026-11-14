import Foundation

/// Settings one workspace overrides. Every nil field inherits `AppSettings`.
struct WorkspaceSettings: Codable, Equatable, Sendable {
    /// Profile for tabs no rule claims; wins over the global default.
    var defaultProfile: String?
    /// Sidebar plugin tab shown until one is picked in this window.
    var sidebarDefaultTab: String?
    /// `SidebarPosition.rawValue`
    var sidebarPosition: Int?
    /// `TabOverflowMode.rawValue`
    var tabOverflowMode: Int?
    /// Status bar segments hidden in this workspace. When set, it replaces the
    /// global visibility of every segment.
    var statusBarHiddenSegments: [String]?

    var isEmpty: Bool { self == WorkspaceSettings() }
}

/// The settings a window uses while a workspace is active: the workspace's
/// value where it has one, else the global one.
struct EffectiveSettings: Equatable {
    var sidebarPosition: SidebarPosition
    var tabOverflowMode: TabOverflowMode
    /// nil: every segment follows its global toggle.
    var statusBarHiddenSegments: Set<String>?
    var sidebarDefaultTab: String?
    var defaultProfile: String?

    static func resolve(
        workspace: WorkspaceSettings?, sidebarPosition: SidebarPosition, tabOverflowMode: TabOverflowMode,
        defaultProfile: String?
    ) -> EffectiveSettings {
        EffectiveSettings(
            sidebarPosition: workspace?.sidebarPosition.flatMap(SidebarPosition.init(rawValue:)) ?? sidebarPosition,
            tabOverflowMode: workspace?.tabOverflowMode.flatMap(TabOverflowMode.init(rawValue:)) ?? tabOverflowMode,
            statusBarHiddenSegments: workspace?.statusBarHiddenSegments.map(Set.init),
            sidebarDefaultTab: workspace?.sidebarDefaultTab,
            defaultProfile: workspace?.defaultProfile ?? defaultProfile)
    }
}

extension AppSettings {
    /// Never stored globally: two windows can show different workspaces.
    func effective(for workspace: Workspace?) -> EffectiveSettings {
        EffectiveSettings.resolve(
            workspace: workspace?.settings, sidebarPosition: sidebarPosition, tabOverflowMode: tabOverflowMode,
            defaultProfile: defaultProfile)
    }
}
