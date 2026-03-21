import Cocoa

/// Position for a status bar segment.
enum StatusBarPosition {
    case left
    case right
}

/// Protocol for pluggable status bar segments.
///
/// Each segment draws itself at a given position and can handle clicks.
/// Register segments in `StatusBarView` via `registerPlugin(_:)`.
protocol StatusBarPlugin: AnyObject {
    /// Unique identifier for this segment.
    var id: String { get }
    /// Position: left or right side of the status bar.
    var position: StatusBarPosition { get }
    /// Priority within position (lower = closer to edge).
    var priority: Int { get }
    /// If set, clicking this segment toggles the corresponding sidebar panel.
    var associatedPanelID: String? { get }
    /// Whether to show this segment given current terminal state.
    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool
    /// Draw the segment and return width consumed.
    /// For left segments: draw starting at x, moving right.
    /// For right segments: draw ending at x, moving left.
    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat
    /// Handle click at point within the given rect. Return true if handled.
    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool
    /// Update cached state (called before draw).
    func update(state: StatusBarState)
    /// Accessibility label for VoiceOver. Return nil to use the segment ID.
    func accessibilitySegmentLabel(state: StatusBarState) -> String?
}

extension StatusBarPlugin {
    var associatedPanelID: String? { nil }
    func accessibilitySegmentLabel(state: StatusBarState) -> String? { nil }
}

/// Snapshot of state available to status bar plugins.
struct StatusBarState {
    var currentDirectory: String
    var paneCount: Int
    var tabCount: Int
    var runningProcess: String
    var visibleSidebarPlugins: Set<String>
    var isRemote: Bool
    var remoteSession: RemoteSessionType?
    var gitBranch: String?
    var gitRepoRoot: String?
    var gitChangedCount: Int = 0
    var sidebarVisible: Bool = true
}
