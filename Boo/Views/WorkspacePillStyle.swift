import Cocoa

/// Single source of truth for how a workspace pill is drawn across all three
/// surfaces — the top bar (`ToolbarView+Drawing.drawWorkspaces`) and the
/// left/right vertical bars (`WorkspaceBarView.drawVertical`). Only geometry
/// (size/shape) and the content drawn inside (label, pin, activity dot) differ
/// per surface; fill, accent border, and close button are identical and live here.
enum WorkspacePillStyle {
    static let cornerRadius: CGFloat = IslandMetrics.controlRadius
    // Active-pill stroke matches the focused pane's island border: same hairline
    // weight, same soft accent alpha — one "this is current" marker everywhere.
    static let borderWidth: CGFloat = IslandMetrics.borderWidth
    static let borderAlpha: CGFloat = IslandMetrics.focusBorderAlpha
    static let borderInset: CGFloat = borderWidth / 2

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

    /// Dissolve a clipped scroll edge into the window backdrop: a two-stop
    /// backdrop-coloured gradient, opaque at `start` and clear at `end`, clipped to
    /// `clipRect`. One copy for the toolbar's horizontal fades and the side
    /// workspace strip's vertical ones — the axis lives in the points.
    @MainActor
    static func drawBackdropFade(
        _ ctx: CGContext, in clipRect: CGRect, from start: CGPoint, to end: CGPoint
    ) {
        drawFade(
            ctx, in: clipRect, from: start, to: end,
            color: AppSettings.shared.theme.windowBackdrop)
    }

    /// Same fade, but into an arbitrary surface colour — the pane tab bar shares
    /// the terminal background rather than the window backdrop.
    static func drawFade(
        _ ctx: CGContext, in clipRect: CGRect, from start: CGPoint, to end: CGPoint,
        color: NSColor
    ) {
        // sRGB conversion, not raw `cgColor.components`: a catalog colour's
        // component layout isn't guaranteed to be RGBA.
        guard let c = color.usingColorSpace(.sRGB) else {
            return
        }
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        guard
            let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                colorComponents: [r, g, b, 1.0, r, g, b, 0.0], locations: nil, count: 2)
        else { return }
        ctx.saveGState()
        ctx.clip(to: clipRect)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        ctx.restoreGState()
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

    /// Alpha the island hairline is drawn at. Only inactive pills carry it — the
    /// active pill takes the accent `strokeBorder` instead. A workspace-coloured
    /// pill's tinted edge is drawn softer than the neutral chrome hairline, since
    /// the tint already belongs to it.
    static func islandBorderAlpha(colored: Bool) -> CGFloat {
        colored ? 0.55 : 1.0
    }

    /// The island hairline every workspace pill carries, tinted by the workspace's
    /// own colour when it has one so the edge reads as part of the pill rather than
    /// generic chrome. Uncoloured pills fall back to the shared island border.
    /// The *active* pill is stroked in the accent instead (`strokeBorder`).
    static func strokeIslandBorder(_ ctx: CGContext, rect: CGRect, wsColor: NSColor?, neutral: NSColor) {
        let color = (wsColor ?? neutral).withAlphaComponent(
            islandBorderAlpha(colored: wsColor != nil))
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
