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

    /// Opaque border color: chromeMuted at 20% blended over chromeBg.
    /// Use this instead of `chromeMuted.withAlphaComponent(0.2)` for borders
    /// so overlapping draws don't produce darker artifacts.
    var chromeBorder: NSColor {
        let alpha: CGFloat = 0.2
        let fg = chromeMuted
        let bg = chromeBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Sidebar border: chromeMuted at 20% blended over sidebarBg.
    var sidebarBorder: NSColor {
        let alpha: CGFloat = 0.2
        let fg = chromeMuted
        let bg = sidebarBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Sidebar row hover fill: chromeMuted at 8% blended over sidebarBg.
    var sidebarRowHover: NSColor {
        let alpha: CGFloat = 0.08
        let fg = chromeMuted
        let bg = sidebarBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

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
struct CustomThemeData: Codable, Identifiable {
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
