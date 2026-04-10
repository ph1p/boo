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

    /// Whether this is a dark theme (background luminance < 0.5).
    var isDark: Bool {
        let r = CGFloat(background.r) / 255
        let g = CGFloat(background.g) / 255
        let b = CGFloat(background.b) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }

    /// Whether this theme was created by the user (not a built-in).
    var isCustom: Bool = false
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
