import Cocoa

/// Single source of truth for how a workspace pill is drawn across all three
/// surfaces — the top bar (`ToolbarView+Drawing.drawWorkspaces`) and the
/// left/right vertical bars (`WorkspaceBarView.drawVertical`). Only geometry
/// (size/shape) and the content drawn inside (label, pin, activity dot) differ
/// per surface; fill, accent border, and close button are identical and live here.
enum WorkspacePillStyle {
    static let cornerRadius: CGFloat = IslandMetrics.controlRadius
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

    /// Fill `rect` as a rounded rect at the shared control radius. The
    /// `setFillColor` / `addPath(CGPath(roundedRect:…))` / `fillPath` incantation
    /// was repeated at a dozen sites across the chrome; this is the one copy.
    /// Set the fill colour on `ctx` before calling.
    static func fillRoundedRect(
        _ ctx: CGContext, rect: CGRect, radius: CGFloat = cornerRadius
    ) {
        ctx.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    /// Label colour for a pill, lightened out of the workspace's own tint so the
    /// text stays legible against the fill. Copied by hand at three draw sites
    /// before this, and the copies had already drifted apart.
    ///
    /// `usingColorSpace(.sRGB)` is load-bearing: `redComponent` and friends *trap*
    /// on a catalog colour (`.systemGreen` and the like), so the conversion is what
    /// keeps an arbitrary `NSColor` from crashing the draw pass.
    static func labelColor(
        wsColor: NSColor?, active: Bool, text: NSColor, muted: NSColor
    ) -> NSColor {
        guard let c = wsColor?.usingColorSpace(.sRGB) else { return active ? text : muted }
        // The active pill sits on a brighter fill, so its label lifts further.
        let (scale, lift): (CGFloat, CGFloat) = active ? (0.6, 0.4) : (0.5, 0.2)
        return NSColor(
            red: c.redComponent * scale + lift, green: c.greenComponent * scale + lift,
            blue: c.blueComponent * scale + lift, alpha: 1)
    }

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
        fillRoundedRect(ctx, rect: rect)
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

    /// Hairline variant of `strokeBorder` at the shared island border weight (1px),
    /// used by the floating hover pill in the side workspace strip — the accent
    /// stroke above is deliberately heavier because it marks the active workspace.
    static func strokeHairline(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        let w = IslandMetrics.borderWidth
        let inset = w / 2
        let strokeRect = rect.insetBy(dx: inset, dy: inset)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(w)
        ctx.addPath(
            CGPath(
                roundedRect: strokeRect, cornerWidth: cornerRadius - inset,
                cornerHeight: cornerRadius - inset, transform: nil))
        ctx.strokePath()
    }

    /// Alpha the island hairline is drawn at. A workspace-coloured pill can carry a
    /// stronger edge than a neutral one without shouting, since the tint already
    /// belongs to it.
    static func islandBorderAlpha(active: Bool, colored: Bool) -> CGFloat {
        if colored { return active ? 0.9 : 0.55 }
        return active ? 0.9 : 1.0
    }

    /// The island hairline every workspace pill carries, tinted by the workspace's
    /// own colour when it has one so the edge reads as part of the pill rather than
    /// generic chrome. Uncoloured pills fall back to the shared island border.
    /// The *active* pill is stroked in the accent instead (`strokeBorder`).
    static func strokeIslandBorder(_ ctx: CGContext, rect: CGRect, wsColor: NSColor?, neutral: NSColor) {
        let color = (wsColor ?? neutral).withAlphaComponent(
            islandBorderAlpha(active: false, colored: wsColor != nil))
        strokeHairline(ctx, rect: rect, color: color)
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
