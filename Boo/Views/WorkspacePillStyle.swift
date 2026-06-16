import Cocoa

/// Single source of truth for how a workspace pill is drawn across all three
/// surfaces — the top bar (`ToolbarView+Drawing.drawWorkspaces`) and the
/// left/right vertical bars (`WorkspaceBarView.drawVertical`). Only geometry
/// (size/shape) and the content drawn inside (label, pin, activity dot) differ
/// per surface; fill, accent border, and close button are identical and live here.
enum WorkspacePillStyle {
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1.5
    static let borderAlpha: CGFloat = 0.9
    static let borderInset: CGFloat = 0.75  // half of borderWidth

    /// Diameter of the hover close-button circle, shared by every surface so the
    /// drawn glyph and its click hit-test can never diverge in size.
    static let closeButtonSize: CGFloat = 16

    /// The "✕" glyph and its measured size — constant, so computed once.
    nonisolated(unsafe) static let closeGlyph = "\u{2715}" as NSString
    static let closeGlyphSize =
        ("\u{2715}" as NSString).size(withAttributes: [.font: ToolbarView.Fonts.closeSmall])

    /// Fill alpha by state. Colored pills sit brighter than the neutral
    /// (`chromeMuted`) fill so the tint stays legible.
    static func fillAlpha(active: Bool, hovered: Bool, colored: Bool) -> CGFloat {
        if colored {
            return active ? 0.25 : (hovered ? 0.18 : 0.12)
        }
        return active ? 0.25 : (hovered ? 0.12 : 0.06)
    }

    /// Fill the pill background for the given state.
    static func fill(
        _ ctx: CGContext, rect: CGRect, active: Bool, hovered: Bool,
        wsColor: NSColor?, neutral: NSColor
    ) {
        let alpha = fillAlpha(active: active, hovered: hovered, colored: wsColor != nil)
        ctx.setFillColor((wsColor ?? neutral).withAlphaComponent(alpha).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        ctx.fillPath()
    }

    /// Stroke the accent border drawn on the active pill.
    static func strokeBorder(_ ctx: CGContext, rect: CGRect, accent: NSColor) {
        let strokeRect = rect.insetBy(dx: borderInset, dy: borderInset)
        ctx.setStrokeColor(accent.withAlphaComponent(borderAlpha).cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.addPath(
            CGPath(
                roundedRect: strokeRect, cornerWidth: cornerRadius - borderInset,
                cornerHeight: cornerRadius - borderInset, transform: nil))
        ctx.strokePath()
    }

    /// Draw the hover close button: opaque background circle, tinted overlay, "✕" glyph.
    static func drawCloseButton(_ ctx: CGContext, in circleRect: CGRect, tint: NSColor, bg: NSColor) {
        ctx.setFillColor(bg.cgColor)
        ctx.fillEllipse(in: circleRect)
        ctx.setFillColor(tint.withAlphaComponent(0.15).cgColor)
        ctx.fillEllipse(in: circleRect)
        let size = closeGlyphSize
        closeGlyph.draw(
            at: NSPoint(
                x: circleRect.midX - size.width / 2,
                y: circleRect.midY - size.height / 2),
            withAttributes: [
                .font: ToolbarView.Fonts.closeSmall,
                .foregroundColor: tint.withAlphaComponent(0.8)
            ])
    }
}
