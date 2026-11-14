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

    private static let builtInThemesByName: [String: TerminalTheme] = {
        var map = [String: TerminalTheme]()
        for t in TerminalTheme.themes { map[t.name] = t }
        return map
    }()

    /// A built-in or custom theme by name; nil when none has that name.
    func theme(named name: String) -> TerminalTheme? {
        if let t = Self.builtInThemesByName[name] { return t }
        let data = UserDefaults.standard.data(forKey: K.customThemes)
        let decoded = data.flatMap { try? JSONDecoder().decode([CustomThemeData].self, from: $0) } ?? []
        return decoded.first(where: { $0.name == name })?.toTheme()
    }

    var theme: TerminalTheme {
        if let preview = previewTheme { return preview }
        let name = themeName
        if let t = Self.builtInThemesByName[name] { return t }
        return resolvedCustomTheme(named: name)
    }

    private func resolvedCustomTheme(named name: String) -> TerminalTheme {
        let data = UserDefaults.standard.data(forKey: K.customThemes)
        customThemeCacheLock.lock()
        defer { customThemeCacheLock.unlock() }
        if let cached = customThemeCache, cached.name == name, cached.data == data {
            return cached.theme
        }
        let decoded = data.flatMap { try? JSONDecoder().decode([CustomThemeData].self, from: $0) } ?? []
        let theme = decoded.first(where: { $0.name == name })?.toTheme() ?? .booDark
        customThemeCache = (name, data, theme)
        return theme
    }

    /// All themes: built-ins followed by user-created custom themes.
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
    @MainActor func applySystemAppearance() {
        guard autoTheme else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let target = isDark ? darkThemeName : lightThemeName
        if target != themeName {
            themeName = target
        }
    }
}
