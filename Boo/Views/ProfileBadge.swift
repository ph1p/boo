import Cocoa

/// The short label a profile puts next to its tab's title.
@MainActor
enum ProfileBadge {
    nonisolated(unsafe) private static let font = NSFont.systemFont(ofSize: 9, weight: .bold)
    private static let padX: CGFloat = 4
    private static let height: CGFloat = 13
    /// Space between the title and the badge.
    static let gap: CGFloat = 5
    private static let maxLength = 12

    /// The badge of the tab's profile; nil when it has none.
    static func text(for tab: Pane.Tab) -> String? {
        guard let badge = ProfileStore.shared.profile(named: tab.state.profile)?.badge else { return nil }
        return String(badge.prefix(maxLength))
    }

    static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + padX * 2
    }

    /// Draws `text` as a pill starting at `x`, centered on `midY`.
    static func draw(_ ctx: CGContext, text: String, x: CGFloat, midY: CGFloat, color: NSColor) {
        let rect = CGRect(x: x, y: midY - height / 2, width: width(of: text), height: height)
        ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.fillPath()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: rect.minX + padX, y: midY - size.height / 2), withAttributes: attrs)
    }
}
