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

    func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
        true
    }

    func draw(
        at x: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings,
        state: StatusBarState, ctx: CGContext
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textColor = theme.chromeText
        let tintColor = resolveTint(theme: theme) ?? theme.chromeMuted
        var cx = x

        // Draw icon if present
        if let iconName = icon,
            let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        {
            let iconSize: CGFloat = 12
            let iconY = (DensityMetrics.current.statusBarHeight - iconSize) / 2
            let iconRect = NSRect(x: cx, y: iconY, width: iconSize, height: iconSize)

            let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                img.draw(in: drawRect)
                tintColor.set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            ctx.saveGState()
            ctx.translateBy(x: iconRect.origin.x, y: iconRect.origin.y + iconRect.height)
            ctx.scaleBy(x: 1, y: -1)
            tinted.draw(
                in: NSRect(origin: .zero, size: iconRect.size),
                from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()

            cx += iconSize + 4
        }

        // Draw text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let str = text as NSString
        str.draw(at: NSPoint(x: cx, y: y), withAttributes: attrs)
        cx += str.size(withAttributes: attrs).width

        return cx - x
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
