import SwiftUI

// MARK: - Design Tokens

/// Single source of truth for settings UI styling.
/// Every sub-view pulls from here instead of re-deriving colors inline.
struct Tokens {
    let theme: TerminalTheme
    var text: Color { Color(nsColor: theme.chromeText) }
    var muted: Color { Color(nsColor: theme.chromeMuted) }
    var accent: Color { Color(nsColor: theme.accentColor) }
    var bg: Color { Color(nsColor: theme.sidebarBg) }
    var chromeBg: Color { Color(nsColor: theme.chromeBg) }
    var border: Color { Color(nsColor: theme.sidebarBorder) }

    /// The island backdrop and hairline, read from the same theme properties the
    /// AppKit chrome uses so the settings window matches the main window rather
    /// than approximating it.
    var backdrop: Color { Color(nsColor: theme.windowBackdrop) }
    var islandBorder: Color { Color(nsColor: theme.islandBorder) }
    var cardBg: Color { Color(nsColor: theme.cardBg) }

    /// Generic mirror: any TerminalTheme color as SwiftUI Color. Every current
    /// and future token is reachable via `t.color(\.hoverFill)` — the named
    /// mirrors below are just ergonomic shorthands for the common ones.
    func color(_ keyPath: KeyPath<TerminalTheme, NSColor>) -> Color {
        Color(nsColor: theme[keyPath: keyPath])
    }

    // Semantic tokens — SwiftUI mirrors of the TerminalTheme derived tokens.
    // Prefer these over `muted.opacity(…)` so alphas stay consistent app-wide.
    var textSecondary: Color { Color(nsColor: theme.textSecondary) }
    var textTertiary: Color { Color(nsColor: theme.textTertiary) }
    var separator: Color { Color(nsColor: theme.separator) }
    var hoverFill: Color { Color(nsColor: theme.hoverFill) }
    var subtleFill: Color { Color(nsColor: theme.subtleFill) }
    var controlFill: Color { Color(nsColor: theme.controlFill) }
    var accentSelectionFill: Color { Color(nsColor: theme.accentSelectionFill) }
    var accentEmphasis: Color { Color(nsColor: theme.accentEmphasis) }
    var focusRing: Color { Color(nsColor: theme.focusRing) }
    var success: Color { Color(nsColor: theme.success) }
    var warning: Color { Color(nsColor: theme.warning) }
    var error: Color { Color(nsColor: theme.error) }
    var info: Color { Color(nsColor: theme.info) }
    var fg: Color {
        Color(
            red: Double(theme.foreground.r) / 255,
            green: Double(theme.foreground.g) / 255,
            blue: Double(theme.foreground.b) / 255)
    }
    var termBg: Color {
        Color(
            red: Double(theme.background.r) / 255,
            green: Double(theme.background.g) / 255,
            blue: Double(theme.background.b) / 255)
    }

    static var current: Tokens { Tokens(theme: AppSettings.shared.theme) }

    static let labelWidth: CGFloat = 112
    static let rowSpacing: CGFloat = 10
    static let sectionPadding: CGFloat = 12
}

// The settings tree reads its tokens from the environment, seeded once per
// render by the root `SettingsView` (which observes theme changes). Reading
// `Tokens.current` directly from a leaf view's `body` is a staleness bug:
// SwiftUI skips re-rendering rows whose stored inputs didn't change, so a
// theme switch leaves them painted with the previous theme's colors.
extension EnvironmentValues {
    @Entry var tokens: Tokens = Tokens(theme: .githubDark)
}
