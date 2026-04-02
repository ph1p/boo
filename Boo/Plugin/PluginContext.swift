import Cocoa
import SwiftUI

/// Tailwind-inspired font scale for sidebar plugins.
///
/// All sizes derive from a single base set in Settings → Sidebar.
/// Use these instead of hardcoding `size: 11` so every plugin
/// respects the user's font-size preference automatically.
///
/// Typical values at base = 12 (default):
///
/// | Name  | Multiplier | Default pt |
/// |-------|-----------|------------|
/// | `xs`  | × 0.75    | 9 pt       |
/// | `sm`  | × 0.875   | 10.5 pt    |
/// | `base`| × 1.0     | 12 pt      |
/// | `lg`  | × 1.125   | 13.5 pt    |
/// | `xl`  | × 1.25    | 15 pt      |
///
/// Example:
/// ```swift
/// Text(label).font(context.fontScale.font(.base))
/// Text(detail).font(context.fontScale.font(.sm, design: .monospaced))
/// ```
struct SidebarFontScale {
    /// The base point size (from Settings → Sidebar → Base Font Size).
    let base: CGFloat
    /// The font family name (from Settings → Sidebar → Content Font). Empty = system default.
    let fontName: String

    init(base: CGFloat, fontName: String = AppSettings.shared.sidebarFontName) {
        self.base = base
        self.fontName = fontName
    }

    /// Named scale steps, matching Tailwind's type-scale ratios.
    enum Step {
        case xs  // × 0.75
        case sm  // × 0.875
        case base  // × 1.0
        case lg  // × 1.125
        case xl  // × 1.25
    }

    /// Resolved point size for a scale step.
    func size(_ step: Step) -> CGFloat {
        switch step {
        case .xs: return (base * 0.75).rounded()
        case .sm: return (base * 0.875).rounded()
        case .base: return base
        case .lg: return (base * 1.125).rounded()
        case .xl: return (base * 1.25).rounded()
        }
    }

    /// SwiftUI Font at the given scale step.
    /// A `design` override (e.g. `.monospaced`) replaces `fontName` when set.
    func font(_ step: Step, design: Font.Design? = nil) -> Font {
        let pt = size(step)
        if let design {
            return .system(size: pt, design: design)
        }
        if fontName.isEmpty {
            return .system(size: pt)
        }
        return .custom(fontName, size: pt)
    }
}

/// Structured context passed to plugins, replacing direct AppSettings.shared access.
/// Plugins receive this instead of reaching into host singletons.
struct PluginContext {
    let terminal: TerminalContext
    let theme: ThemeSnapshot
    let density: SidebarDensity
    let settings: PluginSettingsReader
    /// Tailwind-inspired font scale. Use instead of hardcoded sizes.
    let fontScale: SidebarFontScale
}

/// Immutable snapshot of theme colors that plugins need.
/// Avoids plugins accessing AppSettings.shared.theme directly.
struct ThemeSnapshot {
    let chromeText: NSColor
    let chromeMuted: NSColor
    let accentColor: NSColor
    let sidebarBg: NSColor
    let foreground: NSColor
    let background: NSColor
    let chromeBg: NSColor
    let ansiColors: [NSColor]

    init(from theme: TerminalTheme) {
        self.chromeText = theme.chromeText
        self.chromeMuted = theme.chromeMuted
        self.accentColor = theme.accentColor
        self.sidebarBg = theme.sidebarBg
        self.foreground = theme.foreground.nsColor
        self.background = theme.background.nsColor
        self.chromeBg = theme.chromeBg
        self.ansiColors = theme.ansiColors.map(\.nsColor)
    }
}

/// Scoped settings reader for a single plugin.
/// Plugins use this instead of AppSettings.shared.pluginBool/String/Double.
struct PluginSettingsReader {
    private let pluginID: String

    init(pluginID: String) {
        self.pluginID = pluginID
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        AppSettings.shared.pluginBool(pluginID, key, default: defaultValue)
    }

    func string(_ key: String, default defaultValue: String) -> String {
        AppSettings.shared.pluginString(pluginID, key, default: defaultValue)
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        AppSettings.shared.pluginDouble(pluginID, key, default: defaultValue)
    }
}
