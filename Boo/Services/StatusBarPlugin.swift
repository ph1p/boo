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
    /// Name shown in the status bar settings and context menu.
    var displayName: String { get }
    /// Whether a click does something; drives the hover highlight and the
    /// accessibility role.
    var isClickable: Bool { get }
    /// When the bar is too narrow, visible segments with the highest value
    /// are dropped first. Alerts use 0 so they never collapse.
    var collapsePriority: Int { get }
}

extension StatusBarPlugin {
    func accessibilitySegmentLabel(state: StatusBarState) -> String? { nil }
    var tooltipText: String? { nil }
    var displayName: String { id }
    var isClickable: Bool { false }
    var collapsePriority: Int { 50 }

    /// Draws a semibold colored status label (broadcast, recording) and
    /// returns its full-height hit rect, padded 4pt on each side. Like any
    /// left segment, `draw` returns the bare text width (rect width - 8).
    static func drawAlertLabel(_ text: String, color: NSColor, at x: CGFloat, y: CGFloat) -> NSRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color
        ]
        let str = text as NSString
        let size = str.safeSize(withAttributes: attrs)
        str.safeDraw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        return NSRect(x: x - 4, y: 0, width: size.width + 8, height: DensityMetrics.current.statusBarHeight)
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

/// Draws a tinted SF Symbol into a CGContext, flipping coordinates for correct
/// orientation in the flipped status bar.
func drawStatusBarTintedIcon(_ image: NSImage, color: NSColor, in rect: NSRect, ctx: CGContext) {
    let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
        image.draw(in: drawRect)
        color.set()
        drawRect.fill(using: .sourceAtop)
        return true
    }
    ctx.saveGState()
    ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    tinted.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .sourceOver, fraction: 1.0)
    ctx.restoreGState()
}

/// Draws an optional tinted SF Symbol followed by medium-weight text starting
/// at `x` — the shape of plugin and IPC segments. Returns the width consumed.
func drawStatusBarIconLabel(
    icon: String?, text: String, tint: NSColor, textColor: NSColor, at x: CGFloat, y: CGFloat, ctx: CGContext
) -> CGFloat {
    var cx = x
    if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
        let iconSize: CGFloat = 12
        let iconY = (DensityMetrics.current.statusBarHeight - iconSize) / 2
        drawStatusBarTintedIcon(
            img, color: tint, in: NSRect(x: cx, y: iconY, width: iconSize, height: iconSize), ctx: ctx)
        cx += iconSize + 4
    }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: textColor
    ]
    let str = text as NSString
    str.safeDraw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
    cx += str.safeSize(withAttributes: attrs).width
    return cx - x
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
