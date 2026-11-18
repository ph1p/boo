import Cocoa

/// How far the generated chrome surfaces step away from the terminal
/// background, and how strong borders and muted text are. One global choice,
/// applied to every theme.
enum ChromeContrast: Int, CaseIterable {
    case subtle = 0
    case balanced = 1
    case strong = 2

    var label: String {
        switch self {
        case .subtle: return "Subtle"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        }
    }

    /// Multiplier on the OKLab lightness steps between surfaces.
    var surfaceScale: Double {
        switch self {
        case .subtle: return 0.55
        case .balanced: return 1
        case .strong: return 1.7
        }
    }

    /// Multiplier on border and separator alpha.
    var borderScale: CGFloat {
        switch self {
        case .subtle: return 0.7
        case .balanced: return 1
        case .strong: return 1.5
        }
    }

    /// WCAG contrast muted text keeps against the chrome surface.
    var mutedContrast: Double {
        switch self {
        case .subtle: return 4.5
        case .balanced: return 4.8
        case .strong: return 5.8
        }
    }
}

/// A theme is a terminal palette plus an optional accent. Every UI color is
/// generated from it by one fixed OKLab scale (see `GeneratedChrome`), so any
/// terminal theme, built-in, imported or one of Ghostty's, gets a matching
/// interface without hand-tuned chrome fields.
struct TerminalTheme {
    let name: String
    let foreground: TerminalColor
    let background: TerminalColor
    let cursor: TerminalColor
    let selection: NSColor
    let ansiColors: [TerminalColor]  // 16 colors: 8 normal + 8 bright

    /// The accent the theme author picked; nil lets the engine choose one
    /// from the cursor and ANSI palette.
    let accentOverride: NSColor?

    /// Whether this theme was created by the user (not a built-in).
    let isCustom: Bool

    /// The contrast level the chrome below was generated with.
    let contrast: ChromeContrast

    /// Generated on the first token read. Copies share the result, and themes
    /// that never draw (gallery rows, catalog parsing) skip the work.
    private let chromeCache = ChromeCache()

    private var chrome: GeneratedChrome {
        chromeCache.value {
            GeneratedChrome(
                foreground: foreground, background: background, cursor: cursor, ansi: ansiColors,
                accent: accentOverride, contrast: contrast)
        }
    }

    init(
        name: String, foreground: TerminalColor, background: TerminalColor, cursor: TerminalColor,
        selection: NSColor, ansiColors: [TerminalColor], accent: NSColor? = nil, isCustom: Bool = false,
        contrast: ChromeContrast = .balanced
    ) {
        self.name = name
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansiColors = ansiColors
        self.accentOverride = accent
        self.isCustom = isCustom
        self.contrast = contrast
    }

    /// The same palette with its chrome generated at another contrast level.
    func withContrast(_ level: ChromeContrast) -> TerminalTheme {
        guard level != contrast else { return self }
        return TerminalTheme(
            name: name, foreground: foreground, background: background, cursor: cursor, selection: selection,
            ansiColors: ansiColors, accent: accentOverride, isCustom: isCustom, contrast: level)
    }

    /// Blends `fg` at `alpha` over an opaque `bg`, returning an opaque color.
    /// Prefer this over `withAlphaComponent` for fills/borders that may draw on
    /// top of each other — overlapping translucent draws produce darker artifacts.
    static func blend(_ fg: NSColor, over bg: NSColor, alpha: CGFloat) -> NSColor {
        let f = fg.usingColorSpace(.sRGB) ?? fg
        let b = bg.usingColorSpace(.sRGB) ?? bg
        let r = f.redComponent * alpha + b.redComponent * (1 - alpha)
        let g = f.greenComponent * alpha + b.greenComponent * (1 - alpha)
        let bl = f.blueComponent * alpha + b.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: bl, alpha: 1)
    }

    // MARK: - Generated surfaces
    //
    // Reach for the token that names the ROLE. Full table:
    // documentation/docs/pages/theming.mdx

    /// The gaps between the chrome islands: the deepest surface.
    var surfaceBackdrop: NSColor { chrome.backdrop }

    /// Sidebar, toolbar, status bar, settings and floating panels: one small
    /// OKLab step from the terminal background.
    var surfaceChrome: NSColor { chrome.surface }

    /// Cards and raised rows inside the chrome surface.
    var surfaceRaised: NSColor { chrome.raised }

    /// Backdrop of drag ghosts.
    var surfaceGhost: NSColor { chrome.surface.withAlphaComponent(0.88) }

    // MARK: Text

    /// Primary text and icons on the chrome surface.
    var textPrimary: NSColor { chrome.text }

    /// The muted text hue, at least `contrast.mutedContrast` on the chrome
    /// surface. Consume it through the tokens below rather than raw.
    var textMuted: NSColor { chrome.muted }

    /// Secondary text and glyphs.
    var textSecondary: NSColor { chrome.muted.withAlphaComponent(0.7) }

    /// Tertiary text: placeholders, idle glyphs, inactive icons.
    var textTertiary: NSColor { chrome.muted.withAlphaComponent(0.5) }

    // MARK: Borders and fills

    /// Opaque border for chrome islands whose strokes may overlap-draw.
    var borderChrome: NSColor { chrome.border }

    /// Opaque border for pane islands, blended over the terminal background.
    var borderPane: NSColor { chrome.paneBorder }

    /// Translucent hairline for separators drawn once over varying backgrounds.
    /// If the draw can overlap itself, use `borderChrome` instead.
    var separator: NSColor { chrome.muted.withAlphaComponent(0.2 * contrast.borderScale) }

    /// Hover fill behind rows, segments and tabs.
    var hoverFill: NSColor { chrome.muted.withAlphaComponent(0.10) }

    /// Opaque row hover on the chrome surface.
    var rowHover: NSColor { chrome.rowHover }

    /// Barely-there fill: drag placeholder slots, idle button backgrounds.
    var subtleFill: NSColor { chrome.muted.withAlphaComponent(0.06) }

    /// Fill for small controls: button hover circles, text-field backgrounds.
    var controlFill: NSColor { chrome.muted.withAlphaComponent(0.15) }

    // MARK: Accent

    /// Selection, focus, activity: anything "active". At least 3:1 against
    /// the chrome surface and the terminal background when generated.
    var accent: NSColor { chrome.accent }

    /// Strong accent for active/pressed fills and activity indicators.
    var accentEmphasis: NSColor { chrome.accent.withAlphaComponent(0.85) }

    /// Focus ring around focused text fields.
    var focusRing: NSColor { chrome.accent.withAlphaComponent(0.7) }

    /// Border of the focused pane island.
    var focusBorder: NSColor { chrome.accent.withAlphaComponent(0.45) }

    /// Fill behind the selected item.
    var accentSelectionFill: NSColor { chrome.accent.withAlphaComponent(0.15) }

    // MARK: Status colors
    // Derived from the ANSI palette so every theme gets matching status hues.
    // Theme-independent identity hues (docker blue, SSH amber) stay in
    // BooPaths.swift.

    /// Positive/success status (ANSI green).
    var success: NSColor { ansiGreen.nsColor }
    /// Warning status (ANSI yellow).
    var warning: NSColor { ansiYellow.nsColor }
    /// Error/destructive status (ANSI red).
    var error: NSColor { ansiRed.nsColor }
    /// Informational status (ANSI blue).
    var info: NSColor { ansiBlue.nsColor }

    /// Whether this is a dark theme (background luminance < 0.5).
    var isDark: Bool { background.luminance < 0.5 }

    // MARK: - Editor Helpers

    var ansiRed: TerminalColor { ansiColors[1] }
    var ansiGreen: TerminalColor { ansiColors[2] }
    var ansiYellow: TerminalColor { ansiColors[3] }
    var ansiBlue: TerminalColor { ansiColors[4] }
    var ansiMagenta: TerminalColor { ansiColors[5] }
    var ansiCyan: TerminalColor { ansiColors[6] }
}

// MARK: - Chrome generation

/// The UI colors of a theme, computed once from its terminal palette.
///
/// Surfaces form a lightness ladder in OKLab that keeps the background's hue:
/// pane (the terminal background) → chrome (one step deeper) → backdrop (one
/// more step). A near-black background has no room below it, so its chrome
/// steps up instead and the backdrop stays at the bottom. Text and accent are
/// pushed until they reach their contrast targets on the chrome surface.
private struct GeneratedChrome {
    let backdrop: NSColor
    let surface: NSColor
    let raised: NSColor
    let text: NSColor
    let muted: NSColor
    let accent: NSColor
    let border: NSColor
    let paneBorder: NSColor
    let rowHover: NSColor

    /// OKLab lightness steps at balanced contrast.
    static let chromeStep = 0.022
    static let backdropStep = 0.034
    static let raisedStep = 0.035

    init(
        foreground: TerminalColor, background: TerminalColor, cursor: TerminalColor, ansi: [TerminalColor],
        accent override: NSColor?, contrast: ChromeContrast
    ) {
        let bg = OKLab(background.nsColor)
        let dark = background.luminance < 0.5
        let k = contrast.surfaceScale
        let chromeStep = Self.chromeStep * k
        let backdropStep = Self.backdropStep * k

        // Depth means darker. A background too dark to step below lifts its
        // chrome instead, and the backdrop sinks to near black.
        let roomBelow = bg.l - chromeStep - backdropStep >= 0.04
        let chromeL = roomBelow ? bg.l - chromeStep : bg.l + chromeStep
        let backdropL = max(chromeL - backdropStep, 0)
        let surfaceLab = bg.withLightness(chromeL)
        let surface = surfaceLab.nsColor
        self.surface = surface
        self.backdrop = bg.withLightness(backdropL).nsColor
        self.raised = bg.withLightness(chromeL + (dark ? 1 : -1) * Self.raisedStep * k).nsColor

        let fg = foreground.nsColor
        let text = OKLab.ensureContrast(fg, against: [surface], minimum: 7, lighter: dark)
        self.text = text

        // Muted text: walk from the text toward the surface while the contrast
        // target still holds, so it carries the theme's own tint.
        let textLab = OKLab(text)
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            let candidate = textLab.mixed(with: surfaceLab, amount: mid).nsColor
            if OKLab.contrast(candidate, surface) >= contrast.mutedContrast { lo = mid } else { hi = mid }
        }
        let muted = textLab.mixed(with: surfaceLab, amount: lo).nsColor
        self.muted = muted

        if let override {
            self.accent = override.usingColorSpace(.sRGB) ?? override
        } else {
            let candidates = [cursor] + [12, 4, 13, 5, 14, 6].compactMap { ansi.indices.contains($0) ? ansi[$0] : nil }
            let pick = candidates.first { OKLab($0.nsColor).chroma >= 0.06 } ?? ansi.dropFirst(4).first ?? cursor
            self.accent = OKLab.ensureContrast(
                pick.nsColor, against: [surface, background.nsColor], minimum: 3, lighter: dark)
        }

        let borderAlpha = 0.2 * contrast.borderScale
        self.border = TerminalTheme.blend(muted, over: surface, alpha: borderAlpha)
        self.paneBorder = TerminalTheme.blend(muted, over: background.nsColor, alpha: borderAlpha)
        self.rowHover = TerminalTheme.blend(muted, over: surface, alpha: 0.08)
    }
}

/// A theme's generated chrome once computed. A class, so struct copies of a
/// theme share it instead of each generating their own.
private final class ChromeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: GeneratedChrome?

    func value(_ make: () -> GeneratedChrome) -> GeneratedChrome {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = make()
        cached = made
        return made
    }
}

/// A color in OKLab (Björn Ottosson), the space the chrome ladder steps in:
/// equal lightness steps look equal across hues.
struct OKLab {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Self.linearize(c.redComponent)
        let g = Self.linearize(c.greenComponent)
        let bl = Self.linearize(c.blueComponent)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    var chroma: Double { (a * a + b * b).squareRoot() }

    func withLightness(_ value: Double) -> OKLab { OKLab(l: min(max(value, 0), 1), a: a, b: b) }

    func mixed(with other: OKLab, amount t: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    /// The sRGB color, with chroma reduced until it fits the gamut.
    var nsColor: NSColor {
        var scale = 1.0
        for _ in 0..<12 {
            if let rgb = OKLab(l: l, a: a * scale, b: b * scale).linearRGB(),
                rgb.allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 })
            {
                return Self.encode(rgb)
            }
            scale *= 0.8
        }
        return Self.encode(OKLab(l: l, a: 0, b: 0).linearRGB() ?? [l, l, l])
    }

    private func linearRGB() -> [Double]? {
        let lc = l + 0.3963377774 * a + 0.2158037573 * b
        let mc = l - 0.1055613458 * a - 0.0638541728 * b
        let sc = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = lc * lc * lc
        let m3 = mc * mc * mc
        let s3 = sc * sc * sc
        return [
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        ]
    }

    private static func encode(_ rgb: [Double]) -> NSColor {
        func gamma(_ v: Double) -> CGFloat {
            let x = min(max(v, 0), 1)
            return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: gamma(rgb[0]), green: gamma(rgb[1]), blue: gamma(rgb[2]), alpha: 1)
    }

    /// WCAG contrast ratio between two opaque colors.
    static func contrast(_ x: NSColor, _ y: NSColor) -> Double {
        let lx = relativeLuminance(x)
        let ly = relativeLuminance(y)
        return (max(lx, ly) + 0.05) / (min(lx, ly) + 0.05)
    }

    static func relativeLuminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linearize(c.redComponent) + 0.7152 * linearize(c.greenComponent) + 0.0722
            * linearize(c.blueComponent)
    }

    /// The sRGB transfer function, decoded to linear light.
    private static func linearize(_ v: CGFloat) -> Double {
        let x = Double(v)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// `color`, moved in lightness (lighter or darker) until it reaches
    /// `minimum` contrast against every color in `against`.
    static func ensureContrast(_ color: NSColor, against: [NSColor], minimum: Double, lighter: Bool) -> NSColor {
        func passes(_ c: NSColor) -> Bool { against.allSatisfy { contrast(c, $0) >= minimum } }
        let start = color.usingColorSpace(.sRGB) ?? color
        if passes(start) { return start }
        var lab = OKLab(start)
        for _ in 0..<60 {
            lab = lab.withLightness(lab.l + (lighter ? 0.01 : -0.01))
            let c = lab.nsColor
            if passes(c) || lab.l <= 0 || lab.l >= 1 { return c }
        }
        return lab.nsColor
    }
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

    /// The colour as the terminal surface shows it. Ghostty renders into an
    /// 8-bit Display P3 target, so chrome that meets the terminal without a
    /// seam (tab bar, find bar) takes the same rounded P3 value. The sRGB
    /// colour reaches the screen through another conversion and can end up
    /// one level off, which shows on near-black backgrounds.
    var surfaceColor: NSColor {
        guard let p3 = nsColor.usingColorSpace(.displayP3) else { return nsColor }
        func level(_ value: CGFloat) -> CGFloat { (value * 255).rounded() / 255 }
        return NSColor(
            displayP3Red: level(p3.redComponent), green: level(p3.greenComponent),
            blue: level(p3.blueComponent), alpha: 1)
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

/// Codable form of a user-created theme: the terminal palette and an
/// optional accent. Everything else is generated.
struct CustomThemeData: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var foreground: TerminalColor
    var background: TerminalColor
    var cursor: TerminalColor
    var selectionHex: String  // "#RRGGBB"
    var ansiColors: [TerminalColor]  // 16 entries
    /// "#RRGGBB", or nil for the generated accent.
    var accentHex: String?

    func toTheme(isCustom: Bool = true) -> TerminalTheme {
        TerminalTheme(
            name: name,
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: NSColor(hex: selectionHex) ?? NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.3),
            ansiColors: ansiColors,
            accent: accentHex.flatMap { NSColor(hex: $0) },
            isCustom: isCustom
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
            accentHex: theme.accentOverride?.hexString
        )
    }
}

extension NSColor {
    /// Hex string "#RRGGBB" from this color (in sRGB space).
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#808080" }
        func channel(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", channel(c.redComponent), channel(c.greenComponent), channel(c.blueComponent))
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
