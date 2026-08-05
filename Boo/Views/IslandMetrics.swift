import Cocoa

/// Geometry for the "island" chrome style: every major region (toolbar, sidebar,
/// terminal panes, status bar, side workspace bar) is a rounded card floating on
/// the window backdrop, separated by a uniform gap.
///
/// Single source of truth — layout constraints, split-view divider thickness and
/// every region's `layer.cornerRadius` all read from here, so the look stays
/// consistent when the numbers change.
enum IslandMetrics {
    /// Space between the window edge and the outermost islands, and between
    /// neighbouring islands. Also the split-view divider thickness, so the gap
    /// between panes matches the gap everywhere else.
    static let gap: CGFloat = 8

    /// Vertical breathing room around the header and footer: above the toolbar,
    /// below the status bar, and between each of them and the content between.
    /// Tighter than `gap` because those two are thin strips that paint no fill —
    /// a full gap around them reads as wasted height rather than separation.
    static let barGap: CGFloat = 4

    /// Gap directly *under* the toolbar, where the header meets the panes. Tighter
    /// than `barGap`: the toolbar's own controls already sit inset from its bottom
    /// edge, so the visible distance from the last glyph to the first pane is that
    /// inset plus this — a full `barGap` there reads as a taller header than it is.
    static let headerBottomGap: CGFloat = 2

    /// Gap directly *above* the status bar, where the panes meet the footer — the
    /// mirror of `headerBottomGap`, and tighter than `barGap` for the same reason:
    /// the bar's own content is inset from its top edge.
    static let footerTopGap: CGFloat = 1

    /// Gap below the status bar, to the window's bottom edge. One point tighter
    /// than `barGap`: the bar's text sits high of its box (descender room), so an
    /// equal gap below reads as larger than the one above.
    static let footerBottomGap: CGFloat = 3

    /// Height of the header strip. Read by the layout constraint *and* by
    /// `TrafficLightPositioner`, which has no view to measure and needs the same
    /// number to land the buttons on the header's midline.
    static let toolbarHeight: CGFloat = 38

    /// Extra breathing room between the sidebar tab strip and the sidebar island's
    /// own edge, applied on whichever side the strip docks to (top or bottom). The
    /// pills fill the strip's full height, so without this they touch the island's
    /// rounded corner.
    static let tabBarEdgePadding: CGFloat = 2

    /// Distance from a region's own edge to the content drawn inside it — the
    /// toolbar's first control, the status bar's first segment, the sidebar tab
    /// strip's first pill. Every chrome view derives its padding from this instead
    /// of picking its own, so content lines up across regions.
    ///
    /// Smaller than `gap`: the region already sits a `gap` from its neighbour, and
    /// stacking a second full gap inside it reads as too much air.
    static let contentInset: CGFloat = 6

    /// Top `y` (flipped coords) that centres a title's *cap band* — not its line
    /// box — on the midline of a bar `barHeight` tall. A font's ascender reaches
    /// above its capitals, so centring the line box leaves the visible text riding
    /// low; the eye lines caps up against neighbours (traffic lights, segments).
    /// One copy for the toolbar title, the status-bar segments and the settings
    /// header, which must all sit on the same midline.
    static func capCenteredTitleY(font: NSFont, barHeight: CGFloat) -> CGFloat {
        // `.rounded()`, not `round(...)`: inside this type the latter resolves to
        // `IslandMetrics.round(_:radius:)` below.
        ((barHeight - font.capHeight) / 2 - (font.ascender - font.capHeight)).rounded()
    }

    /// The same cap-band correction as `capCenteredTitleY`, expressed as the
    /// downward offset from a *line-box-centred* layout (how SwiftUI places
    /// `Text` in a frame) to the cap-band-centred position.
    static func capCenterOffset(font: NSFont) -> CGFloat {
        let lineHeight = font.ascender - font.descender
        return (font.capHeight + lineHeight) / 2 - font.ascender
    }

    /// Corner radius for top-level islands (toolbar, sidebar, status bar, panes).
    static let radius: CGFloat = 7

    /// Corner radius for islands nested inside another island (e.g. a pane inside
    /// a split). Slightly tighter so concentric corners look right.
    static let innerRadius: CGFloat = 6

    /// Corner radius for controls drawn *inside* chrome — workspace pills, sidebar
    /// tab pills, toolbar and status-bar hover backgrounds. One value so every
    /// small rounded rect in the chrome shares the island's curvature family
    /// rather than each drawing site picking its own 3/4/5/6.
    static let controlRadius: CGFloat = 5

    /// Hairline around every island — the same weight as the rules panes draw
    /// inside themselves, so nothing outranks the content.
    static let borderWidth: CGFloat = 1

    /// Border colour: the shared chrome rule colour, matching the seams panes
    /// already draw internally.
    @MainActor static var borderColor: NSColor {
        AppSettings.shared.theme.islandBorder
    }

    /// Round `view`'s backing layer as an island and stroke its edge. Layer-backs
    /// the view if needed and clips subviews so custom `draw(_:)` fills and Metal
    /// sublayers both respect the corner.
    ///
    /// The edge colour must be blended over the island's own surface or it
    /// disappears: chrome-coloured islands take the default (`islandBorder`,
    /// blended over chromeBg); sidebar-coloured islands pass
    /// `theme.sidebarBorder`.
    @MainActor static func round(
        _ view: NSView, radius: CGFloat = radius, borderColor: NSColor? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = borderWidth
        layer.borderColor = (borderColor ?? Self.borderColor).cgColor
    }

    /// Re-apply the border colour after a theme change. Corner geometry doesn't
    /// change with the theme, so only the stroke needs refreshing.
    @MainActor static func refreshBorder(_ view: NSView?, color: NSColor? = nil) {
        view?.layer?.borderColor = (color ?? borderColor).cgColor
    }
}
