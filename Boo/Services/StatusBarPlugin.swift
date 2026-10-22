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
    /// Whether to show this segment given current terminal state.
    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool
    /// Draw the segment and return width consumed.
    /// For left segments: draw starting at x, moving right.
    /// For right segments: draw ending at x, moving left.
    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState, ctx: CGContext
    ) -> CGFloat
    /// Handle click at point within the given rect. Return true if handled.
    @MainActor func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool
    /// Update cached state (called before draw).
    func update(state: StatusBarState)
    /// Accessibility label for VoiceOver. Return nil to use the segment ID.
    func accessibilitySegmentLabel(state: StatusBarState) -> String?
    /// Tooltip text shown on hover. Return nil for no tooltip.
    var tooltipText: String? { get }
}

extension StatusBarPlugin {
    func accessibilitySegmentLabel(state: StatusBarState) -> String? { nil }
    var tooltipText: String? { nil }

    /// Draws a semibold colored status label (broadcast, recording) and
    /// returns its full-height hit rect; its width is what `draw` consumes.
    static func drawAlertLabel(_ text: String, color: NSColor, at x: CGFloat, y: CGFloat) -> NSRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color
        ]
        let str = text as NSString
        let size = str.safeSize(withAttributes: attrs)
        str.safeDraw(at: NSPoint(x: x + 4, y: y), withAttributes: attrs)
        return NSRect(x: x, y: 0, width: size.width + 8, height: DensityMetrics.current.statusBarHeight)
    }

    /// Draws a right-side text segment ending at `rx` and returns its
    /// full-height hit rect; its width is what `draw` consumes.
    static func drawLabel(
        _ text: String, attrs: [NSAttributedString.Key: Any], endingAt rx: CGFloat, y: CGFloat
    )
        -> NSRect
    {
        let str = text as NSString
        let size = str.safeSize(withAttributes: attrs)
        str.safeDraw(at: NSPoint(x: rx - size.width - 4, y: y), withAttributes: attrs)
        return NSRect(
            x: rx - size.width - 8, y: 0, width: size.width + 8, height: DensityMetrics.current.statusBarHeight)
    }
}

/// Snapshot of state available to status bar plugins.
struct StatusBarState {
    var currentDirectory: String
    var paneCount: Int
    var tabCount: Int
    var runningProcess: String
    var isRemote: Bool
    var remoteSession: RemoteSessionType?
    var gitBranch: String?
    var gitRepoRoot: String?
    var gitChangedCount: Int = 0
    var sidebarVisible: Bool = true
}
