import Cocoa

extension AppSettings {
    // MARK: - Theme

    var themeName: String {
        get { UserDefaults.standard.string(forKey: K.themeName) ?? "Boo Dark" }
        set { set(newValue, forKey: K.themeName, topic: .theme) }
    }

    var autoTheme: Bool {
        get { bool(K.autoTheme, default: false) }
        set {
            set(newValue, forKey: K.autoTheme, topic: .theme)
            if newValue { DispatchQueue.main.async { AppSettings.shared.applySystemAppearance() } }
        }
    }

    var darkThemeName: String {
        get { UserDefaults.standard.string(forKey: K.darkThemeName) ?? "Boo Dark" }
        set {
            set(newValue, forKey: K.darkThemeName, topic: .theme)
            if autoTheme { DispatchQueue.main.async { AppSettings.shared.applySystemAppearance() } }
        }
    }

    var lightThemeName: String {
        get { UserDefaults.standard.string(forKey: K.lightThemeName) ?? "Boo Light" }
        set {
            set(newValue, forKey: K.lightThemeName, topic: .theme)
            if autoTheme { DispatchQueue.main.async { AppSettings.shared.applySystemAppearance() } }
        }
    }

    /// How strongly the generated chrome stands apart from the terminal
    /// background. Applies to every theme.
    var chromeContrast: ChromeContrast {
        get {
            guard UserDefaults.standard.object(forKey: K.chromeContrast) != nil else { return .balanced }
            return ChromeContrast(rawValue: UserDefaults.standard.integer(forKey: K.chromeContrast)) ?? .balanced
        }
        set { set(newValue.rawValue, forKey: K.chromeContrast, topic: .theme) }
    }

    private static let builtInThemesByName: [String: TerminalTheme] = {
        var map = [String: TerminalTheme]()
        for t in TerminalTheme.themes { map[t.name] = t }
        return map
    }()

    /// A theme by name, at the current chrome contrast: a built-in, then a
    /// custom theme, then one of Ghostty's bundled themes. Nil when none has
    /// that name.
    func theme(named name: String) -> TerminalTheme? {
        unresolvedTheme(named: name)?.withContrast(chromeContrast)
    }

    /// The theme every surface draws with. A preview from Settings or the
    /// command palette wins; an unknown name falls back to Boo Dark.
    var theme: TerminalTheme {
        if let preview = previewTheme { return preview }
        let name = themeName
        let data = UserDefaults.standard.data(forKey: K.customThemes)
        let contrast = chromeContrast
        if let cached = customThemeCacheLock.withLock({ customThemeCache }), cached.name == name,
            cached.data == data, cached.theme.contrast == contrast
        {
            return cached.theme
        }
        let resolved = (unresolvedTheme(named: name) ?? .booDark).withContrast(contrast)
        customThemeCacheLock.withLock { customThemeCache = (name, data, resolved) }
        return resolved
    }

    private func unresolvedTheme(named name: String) -> TerminalTheme? {
        if let t = Self.builtInThemesByName[name] { return t }
        if let custom = customThemes.first(where: { $0.name == name }) { return custom.toTheme() }
        return GhosttyThemeCatalog.shared.theme(named: name)
    }

    /// The curated built-ins followed by user-created custom themes. Ghostty's
    /// catalog is listed separately (`GhosttyThemeCatalog.shared.names`).
    var allThemes: [TerminalTheme] {
        TerminalTheme.themes + customThemes.map { $0.toTheme() }
    }

    var customThemes: [CustomThemeData] {
        get {
            guard let data = UserDefaults.standard.data(forKey: K.customThemes),
                let decoded = try? JSONDecoder().decode([CustomThemeData].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: K.customThemes)
            }
            saveToFile()
            notify(topic: .theme)
        }
    }

    /// First of `base`, "base 2", "base 3", … not present in `taken` — the one
    /// copy of the theme naming policy.
    private static func uniqueName(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// First of `base`, "base 2", … that no existing theme uses.
    func uniqueThemeName(_ base: String) -> String {
        Self.uniqueName(base, taken: Set(allThemes.map { $0.name }))
    }

    /// Persist a custom theme and select it. The one owner of the naming policy:
    /// creating never silently overwrites an existing theme (name gets a unique
    /// suffix), editing replaces the entry named `originalName` in place
    /// (rename-safe — the row is neither lost nor duplicated).
    /// Returns the name the theme was saved under.
    @discardableResult
    func saveCustomTheme(_ theme: CustomThemeData, replacing originalName: String? = nil) -> String {
        var saved = theme
        var customs = customThemes
        let insertAt: Int
        if let originalName, let idx = customs.firstIndex(where: { $0.name == originalName }) {
            customs.remove(at: idx)
            insertAt = idx
        } else {
            insertAt = customs.count
        }
        // Dedupe against builtins + remaining customs (the replaced entry is
        // already removed, so re-saving under the same name stays suffix-free).
        saved.name = Self.uniqueName(
            saved.name, taken: Set(TerminalTheme.themes.map { $0.name } + customs.map { $0.name }))
        customs.insert(saved, at: min(insertAt, customs.count))
        customThemes = customs
        themeName = saved.name
        return saved.name
    }

    /// Apply the correct theme based on system dark/light mode.
    /// `appearanceChanged`: the system switched between dark and light.
    @MainActor func applySystemAppearance(appearanceChanged: Bool = false) {
        guard autoTheme else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let target = isDark ? darkThemeName : lightThemeName
        if target != themeName {
            themeName = target
        } else if appearanceChanged {
            // Workspace themes carry their own light variant, so they follow
            // the appearance even when the global theme stays the same.
            notify(topic: .theme)
        }
    }

    /// Whether themes with a light variant use it right now.
    @MainActor var followsLightAppearance: Bool {
        autoTheme && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
    }

    /// The theme name a workspace asks for; nil when it follows the global
    /// theme. A theme preview in Settings wins over every workspace.
    func themeName(for workspace: WorkspaceSettings?, lightAppearance: Bool) -> String? {
        guard previewTheme == nil else { return nil }
        return SurfaceStyle(profile: nil, workspace: workspace).themeName(lightAppearance: lightAppearance)
    }
}
