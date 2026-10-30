import Cocoa

/// Status bar segment driven by an external process via the IPC socket.
/// Created from `statusbar.set` commands, removed on `statusbar.clear` or client disconnect.
final class ExternalStatusBarSegment: StatusBarPlugin {
    let id: String
    let position: StatusBarPosition
    let priority: Int

    private let text: String
    private let icon: String?
    private let tintName: String?

    init(info: BooSocketServer.ExternalSegmentInfo) {
        self.id = "external.\(info.id)"
        self.text = info.text
        self.icon = info.icon
        self.tintName = info.tint
        self.position = info.position
        self.priority = info.priority
    }

    var displayName: String { "\(text) (external)" }
    var collapsePriority: Int { 60 }

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        true
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings,
        state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        drawStatusBarIconLabel(
            icon: icon, text: text, tint: resolveTint(theme: theme) ?? theme.chromeMuted,
            textColor: theme.chromeText, at: x, y: y, ctx: ctx)
    }

    func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
        false
    }

    func update(state: StatusBarState) {}

    func accessibilitySegmentLabel(state: StatusBarState) -> String? {
        text
    }

    // MARK: - Tint Resolution

    private func resolveTint(theme: TerminalTheme) -> NSColor? {
        guard let name = tintName else { return nil }
        switch name {
        case "red": return .systemRed
        case "green": return .systemGreen
        case "yellow": return .systemYellow
        case "blue": return .systemBlue
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "accent": return theme.accentColor
        default:
            if name.hasPrefix("#"), name.count == 7,
                let val = UInt32(String(name.dropFirst()), radix: 16)
            {
                let r = CGFloat((val >> 16) & 0xFF) / 255.0
                let g = CGFloat((val >> 8) & 0xFF) / 255.0
                let b = CGFloat(val & 0xFF) / 255.0
                return NSColor(red: r, green: g, blue: b, alpha: 1.0)
            }
            return nil
        }
    }
}
