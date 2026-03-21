import Cocoa

enum CursorStyle: Int, CaseIterable {
    case block = 0
    case beam = 1
    case underline = 2
    case blockOutline = 3

    var label: String {
        switch self {
        case .block: return "Block"
        case .beam: return "Beam"
        case .underline: return "Underline"
        case .blockOutline: return "Outline"
        }
    }
}

enum SidebarPosition: Int, CaseIterable {
    case left = 0
    case right = 1

    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

enum WorkspaceBarPosition: Int, CaseIterable {
    case left = 0
    case top = 1
    case right = 2

    var label: String {
        switch self {
        case .left: return "Left"
        case .top: return "Top"
        case .right: return "Right"
        }
    }
}

enum SidebarDensity: Int, CaseIterable {
    case comfortable = 0
    case compact = 1

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

enum TabOverflowMode: Int, CaseIterable {
    case scroll = 0
    case wrap = 1

    var label: String {
        switch self {
        case .scroll: return "Scroll"
        case .wrap: return "Wrap"
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("ExtermSettingsChanged")
}

final class AppSettings {
    static let shared = AppSettings()

    // MARK: - Keys

    private enum K {
        static let themeName = "themeName"
        static let autoTheme = "autoTheme"
        static let darkThemeName = "darkThemeName"
        static let lightThemeName = "lightThemeName"
        static let cursorStyle = "cursorStyle"
        static let fontSize = "fontSize"
        static let fontName = "fontName"

        static let showHiddenFiles = "showHiddenFiles"
        static let explorerIconsEnabled = "explorerIconsEnabled"
        static let explorerFontSize = "explorerFontSize"
        static let explorerFontName = "explorerFontName"
        static let statusBarShowPath = "statusBarShowPath"
        static let statusBarShowGitBranch = "statusBarShowGitBranch"  // legacy, migrated to plugin settings
        static let statusBarShowTime = "statusBarShowTime"
        static let statusBarShowPaneInfo = "statusBarShowPaneInfo"
        static let statusBarShowShell = "statusBarShowShell"
        static let statusBarShowConnection = "statusBarShowConnection"
        static let sidebarPosition = "sidebarPosition"
        static let workspaceBarPosition = "workspaceBarPosition"
        static let sidebarDensity = "sidebarDensity"
        static let tabOverflowMode = "tabOverflowMode"
        static let disabledPluginIDs = "disabledPluginIDs"
        static let sidebarWidth = "sidebarWidth"
        static let pluginSettings = "pluginSettings"
        static let migratedPluginSettings_v1 = "migratedPluginSettings_v1"
    }

    /// Bool from UserDefaults with a custom default (since .bool returns false for unset keys).
    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
    }

    private func set(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        saveToFile()
        notify()
    }

    // MARK: - Theme

    var themeName: String {
        get { UserDefaults.standard.string(forKey: K.themeName) ?? "Default Dark" }
        set { set(newValue, forKey: K.themeName) }
    }

    var autoTheme: Bool {
        get { bool(K.autoTheme, default: false) }
        set {
            set(newValue, forKey: K.autoTheme)
            if newValue { applySystemAppearance() }
        }
    }

    var darkThemeName: String {
        get { UserDefaults.standard.string(forKey: K.darkThemeName) ?? "Default Dark" }
        set {
            set(newValue, forKey: K.darkThemeName)
            if autoTheme { applySystemAppearance() }
        }
    }

    var lightThemeName: String {
        get { UserDefaults.standard.string(forKey: K.lightThemeName) ?? "Solarized Light" }
        set {
            set(newValue, forKey: K.lightThemeName)
            if autoTheme { applySystemAppearance() }
        }
    }

    private static let themesByName: [String: TerminalTheme] = {
        var map = [String: TerminalTheme]()
        for t in TerminalTheme.themes { map[t.name] = t }
        return map
    }()

    var theme: TerminalTheme {
        Self.themesByName[themeName] ?? .defaultDark
    }

    /// Apply the correct theme based on system dark/light mode.
    func applySystemAppearance() {
        guard autoTheme else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let target = isDark ? darkThemeName : lightThemeName
        if target != themeName {
            themeName = target
        }
    }

    // MARK: - Terminal

    var cursorStyle: CursorStyle {
        get { CursorStyle(rawValue: UserDefaults.standard.integer(forKey: K.cursorStyle)) ?? .block }
        set { set(newValue.rawValue, forKey: K.cursorStyle) }
    }

    var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.fontSize)
            return v > 0 ? CGFloat(v) : 14.0
        }
        set { set(Double(newValue), forKey: K.fontSize) }
    }

    var fontName: String {
        get { UserDefaults.standard.string(forKey: K.fontName) ?? "SF Mono" }
        set { set(newValue, forKey: K.fontName) }
    }

    // MARK: - Explorer (proxies to plugin settings)

    var showHiddenFiles: Bool {
        get { pluginBool("file-tree-local", "showHiddenFiles", default: false) }
        set { setPluginSetting("file-tree-local", "showHiddenFiles", newValue) }
    }

    var explorerIconsEnabled: Bool {
        get { pluginBool("file-tree-local", "showIcons", default: true) }
        set { setPluginSetting("file-tree-local", "showIcons", newValue) }
    }

    var explorerFontSize: CGFloat {
        get { CGFloat(pluginDouble("file-tree-local", "fontSize", default: 12.0)) }
        set { setPluginSetting("file-tree-local", "fontSize", Double(newValue)) }
    }

    var explorerFontName: String {
        get { pluginString("file-tree-local", "fontName", default: "") }
        set { setPluginSetting("file-tree-local", "fontName", newValue) }
    }

    // MARK: - Status Bar

    var statusBarShowPath: Bool {
        get { bool(K.statusBarShowPath, default: true) }
        set { set(newValue, forKey: K.statusBarShowPath) }
    }

    var statusBarShowGitBranch: Bool {
        get { pluginBool("git-panel", "showBranch", default: true) }
        set { setPluginSetting("git-panel", "showBranch", newValue) }
    }

    var statusBarShowTime: Bool {
        get { bool(K.statusBarShowTime, default: true) }
        set { set(newValue, forKey: K.statusBarShowTime) }
    }

    var statusBarShowPaneInfo: Bool {
        get { bool(K.statusBarShowPaneInfo, default: true) }
        set { set(newValue, forKey: K.statusBarShowPaneInfo) }
    }

    var statusBarShowShell: Bool {
        get { bool(K.statusBarShowShell, default: false) }
        set { set(newValue, forKey: K.statusBarShowShell) }
    }

    var statusBarShowConnection: Bool {
        get { bool(K.statusBarShowConnection, default: true) }
        set { set(newValue, forKey: K.statusBarShowConnection) }
    }

    // MARK: - Layout

    var sidebarPosition: SidebarPosition {
        get {
            guard UserDefaults.standard.object(forKey: K.sidebarPosition) != nil else { return .right }
            return SidebarPosition(rawValue: UserDefaults.standard.integer(forKey: K.sidebarPosition)) ?? .right
        }
        set { set(newValue.rawValue, forKey: K.sidebarPosition) }
    }

    var workspaceBarPosition: WorkspaceBarPosition {
        get {
            guard UserDefaults.standard.object(forKey: K.workspaceBarPosition) != nil else { return .left }
            return WorkspaceBarPosition(rawValue: UserDefaults.standard.integer(forKey: K.workspaceBarPosition))
                ?? .left
        }
        set { set(newValue.rawValue, forKey: K.workspaceBarPosition) }
    }

    var sidebarDensity: SidebarDensity { .comfortable }

    var sidebarWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.sidebarWidth)
            return v > 0 ? CGFloat(v) : 250
        }
        set { set(Double(newValue), forKey: K.sidebarWidth) }
    }

    var tabOverflowMode: TabOverflowMode {
        get {
            guard UserDefaults.standard.object(forKey: K.tabOverflowMode) != nil else { return .scroll }
            return TabOverflowMode(rawValue: UserDefaults.standard.integer(forKey: K.tabOverflowMode)) ?? .scroll
        }
        set { set(newValue.rawValue, forKey: K.tabOverflowMode) }
    }

    // MARK: - Plugins

    var disabledPluginIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.disabledPluginIDs) ?? [] }
        set { set(newValue, forKey: K.disabledPluginIDs) }
    }

    // MARK: - Plugin Settings

    private var pluginSettingsDict: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: K.pluginSettings) as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: K.pluginSettings) }
    }

    func pluginBool(_ pluginID: String, _ key: String, default defaultValue: Bool) -> Bool {
        guard let dict = pluginSettingsDict[pluginID], let val = dict[key] as? Bool else { return defaultValue }
        return val
    }

    func pluginString(_ pluginID: String, _ key: String, default defaultValue: String) -> String {
        guard let dict = pluginSettingsDict[pluginID], let val = dict[key] as? String else { return defaultValue }
        return val
    }

    func pluginDouble(_ pluginID: String, _ key: String, default defaultValue: Double) -> Double {
        guard let dict = pluginSettingsDict[pluginID], let val = dict[key] as? Double else { return defaultValue }
        return val
    }

    func setPluginSetting(_ pluginID: String, _ key: String, _ value: Any) {
        var all = pluginSettingsDict
        var plugin = all[pluginID] ?? [:]
        plugin[key] = value
        all[pluginID] = plugin
        pluginSettingsDict = all
        saveToFile()
        notify()
    }

    // MARK: - Font Resolution

    func resolvedFont() -> NSFont {
        if let font = NSFont(name: fontName, size: fontSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var availableMonospaceFonts: [String] {
        let fm = NSFontManager.shared
        var fonts: [String] = ["SF Mono"]
        for family in fm.availableFontFamilies {
            if let members = fm.availableMembers(ofFontFamily: family),
                let first = members.first,
                let traits = first[3] as? UInt,
                (traits & UInt(NSFontTraitMask.fixedPitchFontMask.rawValue)) != 0
            {
                fonts.append(family)
            }
        }
        let knownMono = [
            "Menlo", "Monaco", "Courier", "Courier New", "Fira Code", "JetBrains Mono", "Hack", "Source Code Pro",
            "Inconsolata"
        ]
        for name in knownMono {
            if !fonts.contains(name), NSFont(name: name, size: 14) != nil {
                fonts.append(name)
            }
        }
        return fonts.sorted()
    }

    static var availableSystemFonts: [String] {
        var result = ["System Default"]
        result.append(contentsOf: NSFontManager.shared.availableFontFamilies.sorted())
        return result
    }

    private func notify() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    // MARK: - File Persistence (~/.exterm/settings.json)

    private func saveToFile() {
        let dict: [String: Any] = [
            K.themeName: themeName,
            K.autoTheme: autoTheme,
            K.darkThemeName: darkThemeName,
            K.lightThemeName: lightThemeName,
            K.cursorStyle: cursorStyle.rawValue,
            K.fontSize: Double(fontSize),
            K.fontName: fontName,

            K.statusBarShowPath: statusBarShowPath,
            K.statusBarShowTime: statusBarShowTime,
            K.statusBarShowPaneInfo: statusBarShowPaneInfo,
            K.statusBarShowShell: statusBarShowShell,
            K.statusBarShowConnection: statusBarShowConnection,
            K.sidebarPosition: sidebarPosition.rawValue,
            K.workspaceBarPosition: workspaceBarPosition.rawValue,
            K.sidebarWidth: Double(sidebarWidth),
            K.tabOverflowMode: tabOverflowMode.rawValue,
            K.disabledPluginIDs: disabledPluginIDs,
            K.pluginSettings: pluginSettingsDict
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ExtermPaths.settingsFile))
        }
    }

    private func loadFromFile() {
        let path = ExtermPaths.settingsFile
        guard FileManager.default.fileExists(atPath: path),
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Only load values that aren't already in UserDefaults (first launch migration)
        for (key, value) in dict {
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private init() {
        // On first launch, load settings from ~/.exterm/settings.json if it exists
        loadFromFile()
        // Ensure the config directory exists
        _ = ExtermPaths.configDir
        migratePluginSettings()
    }

    private func migratePluginSettings() {
        guard !UserDefaults.standard.bool(forKey: K.migratedPluginSettings_v1) else { return }
        var all = pluginSettingsDict

        // Migrate git branch setting
        if UserDefaults.standard.object(forKey: K.statusBarShowGitBranch) != nil {
            var git = all["git-panel"] ?? [:]
            git["showBranch"] = UserDefaults.standard.bool(forKey: K.statusBarShowGitBranch)
            all["git-panel"] = git
        }

        // Migrate explorer settings
        var ft = all["file-tree-local"] ?? [:]
        if UserDefaults.standard.object(forKey: K.showHiddenFiles) != nil {
            ft["showHiddenFiles"] = UserDefaults.standard.bool(forKey: K.showHiddenFiles)
        }
        if UserDefaults.standard.object(forKey: K.explorerIconsEnabled) != nil {
            ft["showIcons"] = UserDefaults.standard.bool(forKey: K.explorerIconsEnabled)
        }
        if UserDefaults.standard.object(forKey: K.explorerFontSize) != nil {
            let v = UserDefaults.standard.double(forKey: K.explorerFontSize)
            if v > 0 { ft["fontSize"] = v }
        }
        if UserDefaults.standard.object(forKey: K.explorerFontName) != nil {
            ft["fontName"] = UserDefaults.standard.string(forKey: K.explorerFontName) ?? ""
        }
        if !ft.isEmpty { all["file-tree-local"] = ft }

        pluginSettingsDict = all
        UserDefaults.standard.set(true, forKey: K.migratedPluginSettings_v1)
        saveToFile()
    }
}

/// Observable wrapper so SwiftUI views re-render when settings change.
final class SettingsObserver: ObservableObject {
    @Published var revision: Int = 0
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revision += 1
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
