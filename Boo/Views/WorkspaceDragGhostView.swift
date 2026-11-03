import Cocoa

/// Content of the floating ghost while a workspace pill is dragged: the pill
/// itself, drawn with the same `WorkspacePillStyle` fill, border and label colour
/// as the bar it came from, on an opaque chrome backdrop so the translucent fill
/// still reads over whatever is under the cursor.
final class WorkspaceDragGhostView: NSView {
    private let label: String
    private let font: NSFont
    private let centered: Bool
    private let wsColor: NSColor?
    private let active: Bool

    /// `centered` labels sit in the middle (the side strip's initials); others
    /// start at the top bar's leading inset.
    init(size: NSSize, label: String, font: NSFont, centered: Bool, wsColor: NSColor?, active: Bool) {
        self.label = label
        self.font = font
        self.centered = centered
        self.wsColor = wsColor
        self.active = active
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Leading text inset, matching `ToolbarView.drawWorkspaces`.
    static let leadingInset: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let rect = bounds
        ctx.setFillColor(theme.chromeBg.cgColor)
        WorkspacePillStyle.fillRoundedRect(ctx, rect: rect)
        WorkspacePillStyle.fill(
            ctx, rect: rect, active: active, hovered: true, wsColor: wsColor, neutral: theme.chromeMuted)
        if active {
            WorkspacePillStyle.strokeBorder(ctx, rect: rect, theme: theme, color: wsColor)
        } else {
            WorkspacePillStyle.strokeIslandBorder(
                ctx, rect: rect, wsColor: wsColor, neutral: IslandMetrics.borderColor)
        }

        let color = WorkspacePillStyle.labelColor(
            wsColor: wsColor, active: active, text: theme.chromeText, muted: theme.chromeMuted)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]
        let text = label as NSString
        let height = text.size(withAttributes: attrs).height
        let inset = centered ? 0 : Self.leadingInset
        text.draw(
            in: NSRect(x: inset, y: rect.midY - height / 2, width: rect.width - inset * 2, height: height),
            withAttributes: attrs)
    }
}
