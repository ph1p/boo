import Cocoa

struct TerminalTheme {
    let name: String
    let foreground: TerminalColor
    let background: TerminalColor
    let cursor: TerminalColor
    let selection: NSColor
    let ansiColors: [TerminalColor]  // 16 colors: 8 normal + 8 bright

    // UI chrome colors
    let chromeBg: NSColor  // toolbar, status bar
    let chromeText: NSColor
    let chromeMuted: NSColor
    let sidebarBg: NSColor
    let accentColor: NSColor

    /// Blends `fg` at `alpha` over an opaque `bg`, returning an opaque color.
    /// Prefer this over `withAlphaComponent` for fills/borders that may draw on
    /// top of each other — overlapping translucent draws produce darker artifacts.
    static func blend(_ fg: NSColor, over bg: NSColor, alpha: CGFloat) -> NSColor {
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - Derived semantic tokens
    //
    // Every color the UI needs is derived from the 5 chrome tokens (chromeBg,
    // chromeText, chromeMuted, sidebarBg, accentColor) plus the terminal
    // palette. Reach for the semantic token that names the ROLE instead of
    // hand-rolling `chromeMuted.withAlphaComponent(…)` — the alpha vocabulary
    // stays consistent and custom themes keep working everywhere.
    // Full token table: documentation/docs/pages/theming.mdx

    /// Opaque border for chrome surfaces whose strokes may overlap-draw.
    var chromeBorder: NSColor { Self.blend(chromeMuted, over: chromeBg, alpha: 0.2) }

    /// Opaque border for sidebar/panel surfaces whose strokes may overlap-draw.
    var sidebarBorder: NSColor { Self.blend(chromeMuted, over: sidebarBg, alpha: 0.2) }

    /// Translucent hairline for separators drawn once over varying backgrounds.
    /// If the draw can overlap itself, use `chromeBorder`/`sidebarBorder` instead.
    var separator: NSColor { chromeMuted.withAlphaComponent(0.2) }

    /// Secondary text and glyphs.
    var textSecondary: NSColor { chromeMuted.withAlphaComponent(0.7) }

    /// Tertiary text: placeholders, idle glyphs, inactive icons.
    var textTertiary: NSColor { chromeMuted.withAlphaComponent(0.5) }

    /// Hover fill behind rows, segments and tabs.
    var hoverFill: NSColor { chromeMuted.withAlphaComponent(0.10) }

    /// Barely-there fill: drag placeholder slots, idle button backgrounds.
    var subtleFill: NSColor { chromeMuted.withAlphaComponent(0.06) }

    /// Fill for small controls: button hover circles, text-field backgrounds.
    var controlFill: NSColor { chromeMuted.withAlphaComponent(0.15) }

    /// Card surface inside the sidebar/settings: chromeMuted at 12% over sidebarBg.
    var cardBg: NSColor { Self.blend(chromeMuted, over: sidebarBg, alpha: 0.12) }

    /// Strong accent for active/pressed fills and activity indicators.
    var accentEmphasis: NSColor { accentColor.withAlphaComponent(0.85) }

    /// Focus ring around focused text fields.
    var focusRing: NSColor { accentColor.withAlphaComponent(0.7) }

    /// Border of the focused pane island / active workspace pill.
    var focusBorder: NSColor { accentColor.withAlphaComponent(0.45) }

    /// Fill behind the selected item.
    var accentSelectionFill: NSColor { accentColor.withAlphaComponent(0.15) }

    /// Backdrop of drag ghosts — themed stand-in for
    /// `NSColor.windowBackgroundColor`.
    var dragGhostBg: NSColor { chromeBg.withAlphaComponent(0.88) }

    // MARK: Status colors
    // Derived from the ANSI palette so every theme (incl. custom) gets matching
    // status hues without extra fields. These are theme-ADAPTIVE status roles;
    // theme-independent identity hues (docker blue, SSH amber) stay in
    // BooPaths.swift.

    /// Positive/success status (ANSI green).
    var success: NSColor { ansiGreen.nsColor }
    /// Warning status (ANSI yellow).
    var warning: NSColor { ansiYellow.nsColor }
    /// Error/destructive status (ANSI red).
    var error: NSColor { ansiRed.nsColor }
    /// Informational status (ANSI blue).
    var info: NSColor { ansiBlue.nsColor }

    /// Backdrop behind the island chrome — the colour visible in the gaps between
    /// toolbar, sidebar, panes and status bar. Derived from `chromeBg` so it works
    /// for every theme: pushed away from the chrome (darker on dark themes, lighter
    /// on light ones) so the islands read as raised cards.
    var windowBackdrop: NSColor {
        guard let c = chromeBg.usingColorSpace(.sRGB) else { return chromeBg }
        // Dark themes darken, light themes lighten — but a near-black chromeBg has
        // no room to go darker and would clamp to an identical colour, erasing the
        // gaps. Flip direction when the shift would clip, so every theme keeps a
        // visible separation between backdrop and islands.
        let step: CGFloat = 0.06
        let maxComponent = max(c.redComponent, max(c.greenComponent, c.blueComponent))
        let minComponent = min(c.redComponent, min(c.greenComponent, c.blueComponent))
        var amount: CGFloat = isDark ? -step : step
        if amount < 0 && minComponent < step { amount = step }
        if amount > 0 && maxComponent > 1 - step { amount = -step }
        func shift(_ v: CGFloat) -> CGFloat { min(max(v + amount, 0), 1) }
        return NSColor(
            red: shift(c.redComponent),
            green: shift(c.greenComponent),
            blue: shift(c.blueComponent),
            alpha: 1)
    }

    /// Edge stroke around every island. The same colour panes already use for their
    /// internal rules (tab-bar underline, split seams) so the outer edge and the
    /// lines inside it read as one system rather than two competing weights.
    var islandBorder: NSColor { chromeBorder }

    /// Sidebar row hover fill: chromeMuted at 8% blended over sidebarBg (opaque).
    var sidebarRowHover: NSColor { Self.blend(chromeMuted, over: sidebarBg, alpha: 0.08) }

    /// Whether this is a dark theme (background luminance < 0.5).
    var isDark: Bool {
        background.luminance < 0.5
    }

    /// Whether this theme was created by the user (not a built-in).
    var isCustom: Bool = false

    // MARK: - Monaco Helpers

    var ansiRed: TerminalColor { ansiColors[1] }
    var ansiGreen: TerminalColor { ansiColors[2] }
    var ansiYellow: TerminalColor { ansiColors[3] }
    var ansiBlue: TerminalColor { ansiColors[4] }
    var ansiMagenta: TerminalColor { ansiColors[5] }
    var ansiCyan: TerminalColor { ansiColors[6] }
}

// MARK: - Color Models

struct TerminalColor: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    var nsColor: NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Relative luminance (0–1) used for contrast decisions.
    var luminance: Double {
        0.299 * Double(r) / 255 + 0.587 * Double(g) / 255 + 0.114 * Double(b) / 255
    }

    func highlight(_ amount: CGFloat) -> TerminalColor {
        let rf = min(max(CGFloat(r) / 255 + amount, 0), 1)
        let gf = min(max(CGFloat(g) / 255 + amount, 0), 1)
        let bf = min(max(CGFloat(b) / 255 + amount, 0), 1)
        return TerminalColor(r: UInt8(rf * 255), g: UInt8(gf * 255), b: UInt8(bf * 255))
    }

    static let defaultFG = TerminalColor(r: 228, g: 228, b: 232)
    static let defaultBG = TerminalColor(r: 21, g: 21, b: 23)
    static let black = TerminalColor(r: 0, g: 0, b: 0)
    static let white = TerminalColor(r: 255, g: 255, b: 255)

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
}

// MARK: - Custom theme persistence

/// Codable mirror of TerminalTheme used for persisting user-created themes.
struct CustomThemeData: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var foreground: TerminalColor
    var background: TerminalColor
    var cursor: TerminalColor
    var selectionHex: String  // "#RRGGBB"
    var ansiColors: [TerminalColor]  // 16 entries
    var chromeBgHex: String
    var chromeTextHex: String
    var chromeMutedHex: String
    var sidebarBgHex: String
    var accentHex: String

    func toTheme() -> TerminalTheme {
        TerminalTheme(
            name: name,
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: NSColor(hex: selectionHex) ?? NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.3),
            ansiColors: ansiColors,
            chromeBg: NSColor(hex: chromeBgHex) ?? NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
            chromeText: NSColor(hex: chromeTextHex) ?? NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
            chromeMuted: NSColor(hex: chromeMutedHex) ?? NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
            sidebarBg: NSColor(hex: sidebarBgHex) ?? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
            accentColor: NSColor(hex: accentHex) ?? NSColor(red: 0.3, green: 0.56, blue: 0.91, alpha: 1),
            isCustom: true
        )
    }

    static func from(_ theme: TerminalTheme) -> CustomThemeData {
        CustomThemeData(
            name: theme.name,
            foreground: theme.foreground,
            background: theme.background,
            cursor: theme.cursor,
            selectionHex: theme.selection.hexString,
            ansiColors: theme.ansiColors,
            chromeBgHex: theme.chromeBg.hexString,
            chromeTextHex: theme.chromeText.hexString,
            chromeMutedHex: theme.chromeMuted.hexString,
            sidebarBgHex: theme.sidebarBg.hexString,
            accentHex: theme.accentColor.hexString
        )
    }
}

extension NSColor {
    /// Hex string "#RRGGBB" from this color (in sRGB space).
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
