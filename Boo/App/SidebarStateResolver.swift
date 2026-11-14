import Cocoa

enum SidebarStatePersistenceTarget: Equatable {
    case appSettings
    case workspace
    case tab
}

struct SidebarStateEnvironment {
    var defaultState: SidebarWorkspaceState
    var scope: SidebarStateScope
    var position: SidebarPosition
    var splitViewWidth: CGFloat?
    var dividerThickness: CGFloat
    var backingScaleFactor: CGFloat
    var minSidebarWidth: CGFloat = SidebarLayout.minSidebarWidth
    var minContentWidth: CGFloat = SidebarLayout.minTerminalWidth
}

enum SidebarStateResolver {
    static func persistenceTarget(scope: SidebarStateScope) -> SidebarStatePersistenceTarget {
        switch scope {
        case .window: return .appSettings
        case .workspace: return .workspace
        case .tab: return .tab
        }
    }

    /// The tab's own state, then what the workspace remembers, then the
    /// window's. Each scope reads only its own level and the ones above it,
    /// and a level without a value falls through to the next.
    static func effectiveState(
        tabState: SidebarWorkspaceState? = nil,
        workspaceState: SidebarWorkspaceState?,
        environment: SidebarStateEnvironment
    ) -> SidebarWorkspaceState {
        let tab = environment.scope == .tab ? tabState : nil
        let workspace = environment.scope == .window ? nil : workspaceState
        return SidebarWorkspaceState(
            isVisible: tab?.isVisible ?? workspace?.isVisible ?? environment.defaultState.isVisible,
            width: tab?.width ?? workspace?.width ?? environment.defaultState.width
        )
    }

    static func normalizedWidth(
        _ width: CGFloat,
        environment: SidebarStateEnvironment
    ) -> CGFloat {
        guard let splitViewWidth = environment.splitViewWidth, splitViewWidth > 0 else {
            return snappedWidth(width, scale: environment.backingScaleFactor)
        }

        let minWidth = environment.minSidebarWidth
        let maxWidth: CGFloat
        switch environment.position {
        case .left:
            maxWidth = splitViewWidth - environment.minContentWidth
        case .right:
            maxWidth = splitViewWidth - environment.dividerThickness - environment.minContentWidth
        }

        let clampedMaxWidth = max(minWidth, maxWidth)
        let clampedWidth = min(max(width, minWidth), clampedMaxWidth)
        let snappedWidth = snappedWidth(clampedWidth, scale: environment.backingScaleFactor)
        return min(max(snappedWidth, minWidth), clampedMaxWidth)
    }

    static func renderedState(
        from state: SidebarWorkspaceState,
        environment: SidebarStateEnvironment
    ) -> SidebarWorkspaceState {
        SidebarWorkspaceState(
            isVisible: state.isVisible ?? environment.defaultState.isVisible,
            width: state.width.map { normalizedWidth($0, environment: environment) }
                ?? environment.defaultState.width.map { normalizedWidth($0, environment: environment) }
        )
    }

    static func dividerPosition(
        forSidebarWidth width: CGFloat,
        environment: SidebarStateEnvironment
    ) -> CGFloat {
        let normalizedWidth = normalizedWidth(width, environment: environment)
        let splitViewWidth = environment.splitViewWidth ?? 0
        let rawPosition: CGFloat
        switch environment.position {
        case .left:
            rawPosition = normalizedWidth
        case .right:
            rawPosition = splitViewWidth - normalizedWidth - environment.dividerThickness
        }
        return snappedWidth(rawPosition, scale: environment.backingScaleFactor)
    }

    private static func snappedWidth(_ width: CGFloat, scale: CGFloat) -> CGFloat {
        let safeScale = max(scale, 1)
        return (width * safeScale).rounded() / safeScale
    }
}
