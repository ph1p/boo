import Cocoa

/// Structured context passed to plugins, replacing direct AppSettings.shared access.
/// Plugins receive this instead of reaching into host singletons.
struct PluginContext {
    let terminal: TerminalContext
    let theme: ThemeSnapshot
    let density: SidebarDensity
    let settings: PluginSettingsReader
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
