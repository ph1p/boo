import Cocoa
import SwiftUI

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
    /// Tabs as a list in a column on the pane's left.
    case vertical = 2

    var label: String {
        switch self {
        case .scroll: return "Scroll"
        case .wrap: return "Wrap"
        case .vertical: return "Vertical"
        }
    }
}

/// When the floating controls in a pane's top-right corner show.
enum PaneControlsVisibility: Int, CaseIterable {
    case hover = 0
    case focused = 1
    case never = 2

    var label: String {
        switch self {
        case .hover: return "On Hover"
        case .focused: return "Focused Pane"
        case .never: return "Never"
        }
    }
}

/// What happens once a terminal recording is stopped.
enum RecordingStopAction: Int, CaseIterable {
    case toast = 0
    case reveal = 1
    case nothing = 2

    var label: String {
        switch self {
        case .toast: return "Show Toast"
        case .reveal: return "Reveal in Finder"
        case .nothing: return "Nothing"
        }
    }
}

enum NewTabCwdMode: Int, CaseIterable {
    case samePath = 0
    case defaultFolder = 1

    var label: String {
        switch self {
        case .samePath: return "Same Path"
        case .defaultFolder: return "Default Folder"
        }
    }
}

/// A string enum offered as a settings picker via `SettingManifest.choices`.
protocol SettingChoice: RawRepresentable, Hashable where RawValue == String {
    var displayName: String { get }
    /// Maps legacy aliases to their canonical case.
    var normalized: Self { get }
    /// Cases shown in the picker (legacy aliases excluded).
    static var visibleCases: [Self] { get }
}

extension SettingChoice {
    var normalized: Self { self }

    static var choices: [PluginManifest.SettingManifest.Choice] {
        visibleCases.map { .init(value: $0.rawValue, label: $0.displayName) }
    }
}

enum MarkdownOpenMode: String, CaseIterable, Codable, SettingChoice {
    case preview = "preview"
    case builtInEditor = "builtInEditor"
    case terminalEditor = "editor"
    case external = "external"
    /// Legacy value — treated as builtInEditor.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .preview: return "Markdown Preview"
        case .builtInEditor: return "Editor"
        case .terminalEditor: return "Terminal Editor"
        case .external: return "External App"
        case .multiContent: return "Editor"  // hidden legacy alias
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: MarkdownOpenMode { self == .multiContent ? .builtInEditor : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [MarkdownOpenMode] { [.preview, .builtInEditor, .terminalEditor, .external] }
}

enum ImageOpenMode: String, CaseIterable, Codable, SettingChoice {
    case imageViewer = "imageViewer"
    case kitty = "kitty"
    case external = "external"
    /// Legacy value — treated as imageViewer.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .imageViewer: return "Image Viewer"
        case .kitty: return "Inline (Kitty)"
        case .external: return "External App"
        case .multiContent: return "Image Viewer"
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: ImageOpenMode { self == .multiContent ? .imageViewer : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [ImageOpenMode] { [.imageViewer, .kitty, .external] }
}

enum TextOpenMode: String, CaseIterable, Codable, SettingChoice {
    case editor = "editor"
    case terminalEditor = "terminalEditor"
    case external = "external"
    /// Legacy value — treated as editor.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .editor: return "Editor"
        case .terminalEditor: return "Terminal Editor"
        case .external: return "External App"
        case .multiContent: return "Editor"
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: TextOpenMode { self == .multiContent ? .editor : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [TextOpenMode] { [.editor, .terminalEditor, .external] }
}

enum LinkOpenMode: String, CaseIterable, Codable {
    case browserTab = "browserTab"
    case externalBrowser = "externalBrowser"

    var displayName: String {
        switch self {
        case .browserTab: return "Browser Tab"
        case .externalBrowser: return "External Browser"
        }
    }
}

enum SidebarTabBarPosition: String, CaseIterable {
    case top
    case bottom

    var label: String { rawValue.capitalized }
}

/// Identifies a sidebar tab. Built-in tabs use well-known IDs; plugin-contributed tabs
/// use the plugin's ID as their identifier.
struct SidebarTabID: Hashable, Codable, CustomStringConvertible {
    let id: String

    static let explorer = SidebarTabID("explorer")
    static let search = SidebarTabID("search")

    init(_ id: String) { self.id = id }

    var description: String { id }

    // MARK: - Codable
    init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("BooSettingsChanged")
}

/// Topics for fine-grained settings observation.
/// Views subscribe only to the topics they care about, avoiding unnecessary re-renders.
enum SettingsTopic: String, CaseIterable {
    case theme  // theme name, auto-theme, dark/light theme
    case terminal  // cursor style, font size, font name
    case explorer  // show hidden, icons
    case sidebarFont  // sidebar font size/name
    case statusBar  // status bar toggles (path, git, time, pane info, shell, connection)
    case layout  // sidebar position, workspace bar, density, sidebar width, tab overflow
    case plugins  // disabled plugins, default enabled plugins, plugin settings
    case editor  // editor font size, font family
    case notifications  // activity notifications
    case profiles  // default profile, shader
    case links  // link target, external editor
    case history  // command history
    case sync  // sync folder
    case agents  // agent budgets
    case shortcuts  // menu shortcut overrides
}

final class AppSettings {
    nonisolated(unsafe) static let shared = AppSettings()

    /// Show save-error feedback only once per session to avoid spam.
    private var saveErrorShown = false

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
        static let sidebarFontSize = "sidebarFontSize"
        static let sidebarFontName = "sidebarFontName"
        static let statusBarShowPath = "statusBarShowPath"
        static let statusBarShowGitBranch = "statusBarShowGitBranch"  // legacy, migrated to plugin settings
        static let statusBarShowTime = "statusBarShowTime"
        static let statusBarShowPaneInfo = "statusBarShowPaneInfo"
        static let statusBarShowPorts = "statusBarShowPorts"
        static let statusBarShowShell = "statusBarShowShell"
        static let statusBarShowConnection = "statusBarShowConnection"
        static let debugLogging = "debugLogging"
        static let sidebarPosition = "sidebarPosition"
        static let workspaceBarPosition = "workspaceBarPosition"
        static let sidebarDensity = "sidebarDensity"
        static let tabOverflowMode = "tabOverflowMode"
        static let disabledPluginIDs = "disabledPluginIDs"
        static let sidebarPluginOrder = "sidebarPluginOrder"
        static let sidebarWidth = "sidebarWidth"
        static let orchestratorDrawerWidth = "orchestratorDrawerWidth"
        static let quickTerminalEnabled = "quickTerminalEnabled"
        static let quickTerminalHotkey = "quickTerminalHotkey"
        static let quickTerminalHeight = "quickTerminalHeight"
        static let quickTerminalHideOnResign = "quickTerminalHideOnResign"
        static let defaultProfile = "defaultProfile"
        static let terminalShader = "terminalShader"
        static let defaultLinkTarget = "defaultLinkTarget"
        static let externalEditorPreset = "externalEditorPreset"
        static let externalEditorTemplate = "externalEditorTemplate"
        static let historyEnabled = "historyEnabled"
        static let historyIgnorePattern = "historyIgnorePattern"
        static let historyRetentionDays = "historyRetentionDays"
        static let historySearchShortcutEnabled = "historySearchShortcutEnabled"
        static let syncFolder = "syncFolder"
        static let agentBudgetPerTask = "agentBudgetPerTask"
        static let agentBudgetPerDay = "agentBudgetPerDay"
        static let portNotificationsEnabled = "portNotificationsEnabled"
        static let errorAgentButtonEnabled = "errorAgentButtonEnabled"
        static let pluginSettings = "pluginSettings"
        static let migratedPluginSettings_v1 = "migratedPluginSettings_v1"
        static let defaultOffPluginsApplied = "defaultOffPluginsApplied"
        static let fileEditorCommand = "fileEditorCommand"

        static let sidebarDefaultHidden = "sidebarDefaultHidden"
        static let defaultFolder = "defaultFolder"
        static let defaultMainPage = "defaultMainPage"
        static let sshControlMasterApproved = "sshControlMasterApproved"
        static let welcomeShown = "welcomeShown"
        static let customThemes = "customThemes"
        static let newTabCwdMode = "newTabCwdMode"
        static let activeSidebarTab = "activeSidebarTab"
        static let sidebarTabBarPosition = "sidebarTabBarPosition"
        static let sidebarGlobalState = "sidebarGlobalState"
        static let sidebarPerWorkspaceState = "sidebarPerWorkspaceState"
        static let autoColorWorkspaces = "autoColorWorkspaces"
        static let openWorkspaceEditorOnCreate = "openWorkspaceEditorOnCreate"
        static let openGroupEditorOnCreate = "openGroupEditorOnCreate"
        static let newTabsJoinActiveGroup = "newTabsJoinActiveGroup"
        static let paneControlsVisibility = "paneControlsVisibility"
        static let highlightRecordingPane = "highlightRecordingPane"
        static let recordingStopAction = "recordingStopAction"
        static let recordingsFolder = "recordingsFolder"
        static let recordingFileNameTemplate = "recordingFileNameTemplate"
        static let recordingIdleTimeLimit = "recordingIdleTimeLimit"
        static let defaultTabType = "defaultTabType"
        static let autoDetectContentType = "autoDetectContentType"
        static let markdownOpenMode = "markdownOpenMode"
        static let linkOpenMode = "linkOpenMode"
        static let browserHomePage = "browserHomePage"
        static let browserPersistentWebsiteDataEnabled = "browserPersistentWebsiteDataEnabled"
        static let browserHistoryEnabled = "browserHistoryEnabled"
        static let browserHistoryLimit = "browserHistoryLimit"
        static let browserConfirmClose = "browserConfirmClose"

        static let editorFontSize = "editorFontSize"
        static let editorFontName = "editorFontName"
        static let editorTabSize = "editorTabSize"
        static let editorInsertSpaces = "editorInsertSpaces"
        static let editorWordWrap = "editorWordWrap"
        static let editorLineNumbers = "editorLineNumbers"
        static let editorMinimap = "editorMinimap"
        static let editorFormatOnSave = "editorFormatOnSave"
        static let editorRulerColumn = "editorRulerColumn"
        static let editorDetectIndentation = "editorDetectIndentation"
        static let editorRenderWhitespace = "editorRenderWhitespace"
        static let editorBracketPairColors = "editorBracketPairColors"
        static let editorStickyScroll = "editorStickyScroll"
        static let editorFontLigatures = "editorFontLigatures"
        static let editorCursorStyle = "editorCursorStyle"
        static let editorCursorBlinking = "editorCursorBlinking"
        static let editorAutosave = "editorAutosave"
        static let editorReloadOnExternalChange = "editorReloadOnExternalChange"
        static let editorShowStatusStrip = "editorShowStatusStrip"
        static let editorTrimTrailingWhitespace = "editorTrimTrailingWhitespace"
        static let editorInsertFinalNewline = "editorInsertFinalNewline"

        static let activityNotificationsEnabled = "activityNotificationsEnabled"
        static let notifyMinCommandSeconds = "notifyMinCommandSeconds"
        static let notificationGroupBursts = "notificationGroupBursts"
        static let notificationExpiryMinutes = "notificationExpiryMinutes"
        static let phonePushURL = "phonePushURL"
        static let phonePushMinCommandSeconds = "phonePushMinCommandSeconds"

        static let remoteControlPort = "remoteControlPort"
        static let secureKeyboardEntry = "secureKeyboardEntry"
        static let restoreScrollback = "restoreScrollback"
        static let tmuxIntegration = "tmuxIntegration"
        static let shortcutOverrides = "shortcutOverrides"

        static let paletteRecents = "paletteRecents"
    }

    /// Bool from UserDefaults with a custom default (since .bool returns false for unset keys).
    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
    }

    private func set(_ value: Any?, forKey key: String, topic: SettingsTopic? = nil) {
        UserDefaults.standard.set(value, forKey: key)
        saveToFile()
        notify(topic: topic)
    }

    // MARK: - Theme

    var themeName: String {
        get { UserDefaults.standard.string(forKey: K.themeName) ?? "Default Dark" }
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
        get { UserDefaults.standard.string(forKey: K.darkThemeName) ?? "Default Dark" }
        set {
            set(newValue, forKey: K.darkThemeName, topic: .theme)
            if autoTheme { DispatchQueue.main.async { AppSettings.shared.applySystemAppearance() } }
        }
    }

    var lightThemeName: String {
        get { UserDefaults.standard.string(forKey: K.lightThemeName) ?? "Solarized Light" }
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

    /// Transient theme override shown while the custom-theme editor is open —
    /// the whole UI restyles live as colors are picked. Never persisted;
    /// cleared (nil) when the editor saves or cancels.
    var previewTheme: TerminalTheme? {
        didSet { notify(topic: .theme) }
    }

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

    /// Last resolved custom theme, keyed by name and the raw stored bytes.
    /// `theme` is read from every draw(); decoding all custom themes from JSON
    /// each time was measurable. Keying on the stored Data (not a notification)
    /// keeps the cache correct for any writer of the defaults key.
    private var customThemeCache: (name: String, data: Data?, theme: TerminalTheme)?
    private let customThemeCacheLock = NSLock()

    private func resolvedCustomTheme(named name: String) -> TerminalTheme {
        let data = UserDefaults.standard.data(forKey: K.customThemes)
        customThemeCacheLock.lock()
        defer { customThemeCacheLock.unlock() }
        if let cached = customThemeCache, cached.name == name, cached.data == data {
            return cached.theme
        }
        let decoded = data.flatMap { try? JSONDecoder().decode([CustomThemeData].self, from: $0) } ?? []
        let theme = decoded.first(where: { $0.name == name })?.toTheme() ?? .defaultDark
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

    // MARK: - Terminal

    var cursorStyle: CursorStyle {
        get { CursorStyle(rawValue: UserDefaults.standard.integer(forKey: K.cursorStyle)) ?? .block }
        set { set(newValue.rawValue, forKey: K.cursorStyle, topic: .terminal) }
    }

    var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.fontSize)
            return v > 0 ? CGFloat(v) : 13.0
        }
        set { set(Double(newValue), forKey: K.fontSize, topic: .terminal) }
    }

    var fontName: String {
        get { UserDefaults.standard.string(forKey: K.fontName) ?? "SF Mono" }
        set { set(newValue, forKey: K.fontName, topic: .terminal) }
    }

    // MARK: - Explorer (proxies to plugin settings)

    var showHiddenFiles: Bool {
        get { pluginBool("file-tree-local", "showHiddenFiles", default: false) }
        set { setPluginSetting("file-tree-local", "showHiddenFiles", newValue, topic: .explorer) }
    }

    var explorerIconsEnabled: Bool {
        get { pluginBool("file-tree-local", "showIcons", default: true) }
        set { setPluginSetting("file-tree-local", "showIcons", newValue, topic: .explorer) }
    }

    // Read-only: these are written by the plugin settings UI (topic `.plugins`).
    var explorerShowFilterBar: Bool { pluginBool("file-tree-local", "showFilterBar", default: true) }

    /// Tint names and badge files/folders with their `git status`.
    var explorerGitDecorations: Bool { pluginBool("file-tree-local", "gitDecorations", default: true) }

    var explorerDimIgnored: Bool { pluginBool("file-tree-local", "dimIgnored", default: true) }

    var explorerShowNavigationBar: Bool { pluginBool("file-tree-local", "showNavigationBar", default: true) }

    /// Whether `..`, Go Up and Browse Folder move the explorer or `cd` the shell.
    var explorerNavigationMode: ExplorerNavigationMode {
        ExplorerNavigationMode(rawValue: pluginString("file-tree-local", "navigationMode", default: "browse"))
            ?? .browse
    }

    /// A detached explorer snaps back to the terminal's folder when the shell changes directory.
    var explorerFollowTerminal: Bool { pluginBool("file-tree-local", "followTerminal", default: true) }

    /// Command used to open files from the file tree (e.g. "vim", "nvim", "nano").
    /// Empty string means use $EDITOR env var, falling back to "vi".
    var fileEditorCommand: String {
        get { UserDefaults.standard.string(forKey: K.fileEditorCommand) ?? "" }
        set { set(newValue, forKey: K.fileEditorCommand, topic: .explorer) }
    }

    /// Global base font size for the sidebar. All sidebar content scales from this.
    var sidebarFontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.sidebarFontSize)
            return v > 0 ? CGFloat(v) : 12.0
        }
        set { set(Double(newValue), forKey: K.sidebarFontSize, topic: .sidebarFont) }
    }

    /// Global font family for sidebar content (not applied to headers). Empty string = system default.
    var sidebarFontName: String {
        get { UserDefaults.standard.string(forKey: K.sidebarFontName) ?? "" }
        set { set(newValue, forKey: K.sidebarFontName, topic: .sidebarFont) }
    }

    // MARK: - Status Bar

    var statusBarShowPath: Bool {
        get { bool(K.statusBarShowPath, default: true) }
        set { set(newValue, forKey: K.statusBarShowPath, topic: .statusBar) }
    }

    var statusBarShowGitBranch: Bool {
        get { pluginBool("git-panel", "showBranch", default: true) }
        set { setPluginSetting("git-panel", "showBranch", newValue, topic: .statusBar) }
    }

    var statusBarShowTime: Bool {
        get { bool(K.statusBarShowTime, default: true) }
        set { set(newValue, forKey: K.statusBarShowTime, topic: .statusBar) }
    }

    var statusBarShowPaneInfo: Bool {
        get { bool(K.statusBarShowPaneInfo, default: true) }
        set { set(newValue, forKey: K.statusBarShowPaneInfo, topic: .statusBar) }
    }

    /// Listening ports of the active workspace's processes.
    var statusBarShowPorts: Bool {
        get { bool(K.statusBarShowPorts, default: true) }
        set { set(newValue, forKey: K.statusBarShowPorts, topic: .statusBar) }
    }

    var statusBarShowShell: Bool {
        get { bool(K.statusBarShowShell, default: false) }
        set { set(newValue, forKey: K.statusBarShowShell, topic: .statusBar) }
    }

    var statusBarShowConnection: Bool {
        get { bool(K.statusBarShowConnection, default: true) }
        set { set(newValue, forKey: K.statusBarShowConnection, topic: .statusBar) }
    }

    // MARK: - Debug

    var debugLogging: Bool {
        get { bool(K.debugLogging, default: false) }
        set { set(newValue, forKey: K.debugLogging) }
    }

    // MARK: - Layout

    var sidebarPosition: SidebarPosition {
        get {
            guard UserDefaults.standard.object(forKey: K.sidebarPosition) != nil else { return .right }
            return SidebarPosition(rawValue: UserDefaults.standard.integer(forKey: K.sidebarPosition)) ?? .right
        }
        set { set(newValue.rawValue, forKey: K.sidebarPosition, topic: .layout) }
    }

    var workspaceBarPosition: WorkspaceBarPosition {
        get {
            guard UserDefaults.standard.object(forKey: K.workspaceBarPosition) != nil else { return .top }
            return WorkspaceBarPosition(rawValue: UserDefaults.standard.integer(forKey: K.workspaceBarPosition))
                ?? .top
        }
        set { set(newValue.rawValue, forKey: K.workspaceBarPosition, topic: .layout) }
    }

    /// Path to open as the working directory for new workspaces. Defaults to the user's home directory.
    var defaultFolder: String {
        get {
            UserDefaults.standard.string(forKey: K.defaultFolder)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        set { set(newValue, forKey: K.defaultFolder, topic: .layout) }
    }

    var defaultMainPage: String {
        get { UserDefaults.standard.string(forKey: K.defaultMainPage) ?? "" }
        set { set(newValue, forKey: K.defaultMainPage, topic: .layout) }
    }

    var sidebarDensity: SidebarDensity { .comfortable }

    var sidebarWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.sidebarWidth)
            return v > 0 ? CGFloat(v) : 250
        }
        set { set(Double(newValue), forKey: K.sidebarWidth, topic: .layout) }
    }

    /// The orchestrator drawer's width; the drawer clamps it to the window.
    var orchestratorDrawerWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.orchestratorDrawerWidth)
            return v > 0 ? CGFloat(v) : 420
        }
        set { set(Double(newValue), forKey: K.orchestratorDrawerWidth) }
    }

    // MARK: - Quick Terminal

    /// Registers the quick terminal's global hotkey.
    var quickTerminalEnabled: Bool {
        get { bool(K.quickTerminalEnabled, default: true) }
        set { set(newValue, forKey: K.quickTerminalEnabled) }
    }

    /// The global hotkey, e.g. "opt+space" (see `HotKeySpec.parse`).
    var quickTerminalHotkey: String {
        get { UserDefaults.standard.string(forKey: K.quickTerminalHotkey) ?? "opt+space" }
        set { set(newValue, forKey: K.quickTerminalHotkey) }
    }

    /// The quick terminal's height as a fraction of the screen.
    var quickTerminalHeight: Double {
        get {
            let v = UserDefaults.standard.double(forKey: K.quickTerminalHeight)
            return v > 0 ? min(max(v, 0.2), 0.9) : 0.4
        }
        set { set(min(max(newValue, 0.2), 0.9), forKey: K.quickTerminalHeight) }
    }

    /// Hides the quick terminal when it loses focus.
    var quickTerminalHideOnResign: Bool {
        get { bool(K.quickTerminalHideOnResign, default: true) }
        set { set(newValue, forKey: K.quickTerminalHideOnResign) }
    }

    // MARK: - Profiles

    /// Profile applied to tabs no rule or override picks; nil = plain settings.
    var defaultProfile: String? {
        get { UserDefaults.standard.string(forKey: K.defaultProfile).flatMap { $0.isEmpty ? nil : $0 } }
        set { set(newValue ?? "", forKey: K.defaultProfile, topic: .profiles) }
    }

    /// Global terminal shader: a preset name, a GLSL file path, or "" for none.
    var terminalShader: String {
        get { UserDefaults.standard.string(forKey: K.terminalShader) ?? "" }
        set { set(newValue, forKey: K.terminalShader, topic: .terminal) }
    }

    // MARK: - Links

    /// Where ⌘-clicked `file:line` links open; ⌘⌥-click uses the other one.
    var defaultLinkTarget: LinkTarget {
        get { UserDefaults.standard.string(forKey: K.defaultLinkTarget).flatMap(LinkTarget.init) ?? .monaco }
        set { set(newValue.rawValue, forKey: K.defaultLinkTarget, topic: .links) }
    }

    var externalEditorPreset: ExternalEditorPreset {
        get {
            UserDefaults.standard.string(forKey: K.externalEditorPreset).flatMap(ExternalEditorPreset.init)
                ?? .vscode
        }
        set { set(newValue.rawValue, forKey: K.externalEditorPreset, topic: .links) }
    }

    /// Template for `.custom`: `{path}`, `{line}`, `{col}`; a URL or a shell command.
    var externalEditorTemplate: String {
        get { UserDefaults.standard.string(forKey: K.externalEditorTemplate) ?? "" }
        set { set(newValue, forKey: K.externalEditorTemplate, topic: .links) }
    }

    // MARK: - History

    var historyEnabled: Bool {
        get { bool(K.historyEnabled, default: true) }
        set { set(newValue, forKey: K.historyEnabled, topic: .history) }
    }

    static let defaultHistoryIgnorePattern = #"^\s|(?i)(token|secret|password|passwd|api_key|apikey)="#

    /// Commands matching this regex aren't recorded.
    var historyIgnorePattern: String {
        get { UserDefaults.standard.string(forKey: K.historyIgnorePattern) ?? Self.defaultHistoryIgnorePattern }
        set { set(newValue, forKey: K.historyIgnorePattern, topic: .history) }
    }

    /// Entries older than this are pruned; 0 keeps everything.
    var historyRetentionDays: Int {
        get {
            UserDefaults.standard.object(forKey: K.historyRetentionDays) == nil
                ? 365 : UserDefaults.standard.integer(forKey: K.historyRetentionDays)
        }
        set { set(max(0, newValue), forKey: K.historyRetentionDays, topic: .history) }
    }

    /// ⌃R opens Boo's history search in shells with Boo integration.
    var historySearchShortcutEnabled: Bool {
        get { bool(K.historySearchShortcutEnabled, default: true) }
        set { set(newValue, forKey: K.historySearchShortcutEnabled, topic: .history) }
    }

    // MARK: - Sync

    /// Folder (e.g. in iCloud Drive) mirrored with `~/.boo`; "" = off.
    var syncFolder: String {
        get { UserDefaults.standard.string(forKey: K.syncFolder) ?? "" }
        set { set(newValue, forKey: K.syncFolder, topic: .sync) }
    }

    /// Keys mirrored to the sync folder. Left out: machine paths (default
    /// folder, recordings folder, editor commands), per-machine layout and
    /// state, the sync folder itself and security decisions.
    static let syncedKeys: [String] = [
        K.themeName, K.autoTheme, K.darkThemeName, K.lightThemeName, K.cursorStyle, K.fontSize, K.fontName,
        K.statusBarShowPath, K.statusBarShowTime, K.statusBarShowPaneInfo, K.statusBarShowPorts,
        K.statusBarShowShell, K.statusBarShowConnection, K.sidebarPosition, K.workspaceBarPosition,
        K.sidebarDefaultHidden, K.tabOverflowMode, K.defaultTabType, K.autoDetectContentType, K.browserHomePage,
        K.browserConfirmClose, K.linkOpenMode, K.disabledPluginIDs, K.sidebarPluginOrder, K.pluginSettings,
        K.sidebarFontSize, K.sidebarFontName, K.sidebarTabBarPosition, K.autoColorWorkspaces,
        K.openWorkspaceEditorOnCreate, K.openGroupEditorOnCreate, K.newTabsJoinActiveGroup,
        K.paneControlsVisibility, K.highlightRecordingPane, K.recordingStopAction, K.recordingFileNameTemplate,
        K.recordingIdleTimeLimit, K.editorFontSize, K.editorFontName, K.editorTabSize, K.editorInsertSpaces,
        K.editorWordWrap, K.editorLineNumbers, K.editorMinimap, K.editorFormatOnSave, K.editorRulerColumn,
        K.editorDetectIndentation, K.editorRenderWhitespace, K.editorBracketPairColors, K.editorStickyScroll,
        K.editorFontLigatures, K.editorCursorStyle, K.editorCursorBlinking, K.editorAutosave,
        K.editorReloadOnExternalChange, K.editorShowStatusStrip, K.editorTrimTrailingWhitespace,
        K.editorInsertFinalNewline,
        K.quickTerminalEnabled, K.quickTerminalHotkey, K.quickTerminalHeight, K.quickTerminalHideOnResign,
        K.defaultProfile, K.terminalShader, K.defaultLinkTarget, K.externalEditorPreset, K.historyEnabled,
        K.historyIgnorePattern, K.historyRetentionDays, K.historySearchShortcutEnabled, K.agentBudgetPerTask,
        K.agentBudgetPerDay, K.portNotificationsEnabled, K.errorAgentButtonEnabled, K.notifyMinCommandSeconds,
        K.notificationGroupBursts, K.notificationExpiryMinutes, K.shortcutOverrides
    ]

    static let syncedCustomThemesKey = "customThemes"

    /// The synced subset of the settings, plus custom themes, as JSON values.
    func syncSnapshot() -> [String: Any] {
        let all = fileDictionary()
        var dict: [String: Any] = [:]
        for key in Self.syncedKeys { dict[key] = all[key] }
        if let data = UserDefaults.standard.data(forKey: K.customThemes),
            let themes = try? JSONSerialization.jsonObject(with: data)
        {
            dict[Self.syncedCustomThemesKey] = themes
        }
        return dict
    }

    /// Applies a snapshot pulled from the sync folder. Unknown keys are ignored.
    func applySyncSnapshot(_ dict: [String: Any]) {
        for key in Self.syncedKeys {
            if let value = dict[key] { UserDefaults.standard.set(value, forKey: key) }
        }
        if let themes = dict[Self.syncedCustomThemesKey],
            let data = try? JSONSerialization.data(withJSONObject: themes)
        {
            UserDefaults.standard.set(data, forKey: K.customThemes)
        }
        _disabledPluginIDsSet = nil
        _pluginSettingsDict = nil
        saveToFile()
        notify()
        if autoTheme { DispatchQueue.main.async { AppSettings.shared.applySystemAppearance() } }
    }

    // MARK: - Agents

    /// Warn when one agent task's estimated cost passes this (USD); nil = off.
    var agentBudgetPerTask: Double? {
        get { positiveDouble(K.agentBudgetPerTask) }
        set { set(newValue ?? 0, forKey: K.agentBudgetPerTask, topic: .agents) }
    }

    /// Warn when today's estimated agent cost passes this (USD); nil = off.
    var agentBudgetPerDay: Double? {
        get { positiveDouble(K.agentBudgetPerDay) }
        set { set(newValue ?? 0, forKey: K.agentBudgetPerDay, topic: .agents) }
    }

    private func positiveDouble(_ key: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : nil
    }

    /// Notify when a process in the active workspace starts listening on a port.
    var portNotificationsEnabled: Bool {
        get { bool(K.portNotificationsEnabled, default: true) }
        set { set(newValue, forKey: K.portNotificationsEnabled, topic: .notifications) }
    }

    /// Hover button on failed command blocks that sends them to an agent.
    var errorAgentButtonEnabled: Bool {
        get { bool(K.errorAgentButtonEnabled, default: true) }
        set { set(newValue, forKey: K.errorAgentButtonEnabled, topic: .agents) }
    }

    /// When true, the sidebar starts hidden in new windows.
    var sidebarDefaultHidden: Bool {
        get { bool(K.sidebarDefaultHidden, default: false) }
        set { set(newValue, forKey: K.sidebarDefaultHidden, topic: .layout) }
    }

    /// Stores the sidebar state a new window starts with. Silent: each open
    /// window keeps its own sidebar state, so no window should react to this.
    func rememberSidebarDefaults(hidden: Bool?, width: CGFloat?) {
        var changed = false
        if let hidden, sidebarDefaultHidden != hidden {
            UserDefaults.standard.set(hidden, forKey: K.sidebarDefaultHidden)
            changed = true
        }
        if let width, width > 0, abs(sidebarWidth - width) > 0.001 {
            UserDefaults.standard.set(Double(width), forKey: K.sidebarWidth)
            changed = true
        }
        if changed { saveToFile() }
    }

    var tabOverflowMode: TabOverflowMode {
        get {
            guard UserDefaults.standard.object(forKey: K.tabOverflowMode) != nil else { return .scroll }
            return TabOverflowMode(rawValue: UserDefaults.standard.integer(forKey: K.tabOverflowMode)) ?? .scroll
        }
        set { set(newValue.rawValue, forKey: K.tabOverflowMode, topic: .layout) }
    }

    var newTabCwdMode: NewTabCwdMode {
        get {
            NewTabCwdMode(rawValue: UserDefaults.standard.integer(forKey: K.newTabCwdMode)) ?? .samePath
        }
        set { set(newValue.rawValue, forKey: K.newTabCwdMode, topic: .layout) }
    }

    var sidebarTabBarPosition: SidebarTabBarPosition {
        get {
            SidebarTabBarPosition(rawValue: UserDefaults.standard.string(forKey: K.sidebarTabBarPosition) ?? "")
                ?? .bottom
        }
        set { set(newValue.rawValue, forKey: K.sidebarTabBarPosition, topic: .layout) }
    }

    /// When true, the sidebar keeps its own state independently of terminal tabs —
    /// switching tabs does not change the active plugin, expanded sections, or scroll position.
    var sidebarGlobalState: Bool {
        get { bool(K.sidebarGlobalState, default: false) }
        set { set(newValue, forKey: K.sidebarGlobalState, topic: .layout) }
    }

    /// When true, each workspace remembers its own sidebar visibility and width.
    var sidebarPerWorkspaceState: Bool {
        get { bool(K.sidebarPerWorkspaceState, default: false) }
        set { set(newValue, forKey: K.sidebarPerWorkspaceState, topic: .layout) }
    }

    /// When true, new workspaces get a color derived from their git root.
    /// A color picked by hand replaces it.
    var autoColorWorkspaces: Bool {
        get { bool(K.autoColorWorkspaces, default: false) }
        set { set(newValue, forKey: K.autoColorWorkspaces, topic: .layout) }
    }

    /// When true, a workspace created from the + button or menu opens its
    /// name/color editor right away.
    var openWorkspaceEditorOnCreate: Bool {
        get { bool(K.openWorkspaceEditorOnCreate, default: true) }
        set { set(newValue, forKey: K.openWorkspaceEditorOnCreate, topic: .layout) }
    }

    /// When true, a new tab group opens its name/color editor right away.
    var openGroupEditorOnCreate: Bool {
        get { bool(K.openGroupEditorOnCreate, default: true) }
        set { set(newValue, forKey: K.openGroupEditorOnCreate, topic: .layout) }
    }

    /// When true, a new tab opened from a grouped tab joins that tab's group.
    var newTabsJoinActiveGroup: Bool {
        get { bool(K.newTabsJoinActiveGroup, default: true) }
        set { set(newValue, forKey: K.newTabsJoinActiveGroup, topic: .layout) }
    }

    var paneControlsVisibility: PaneControlsVisibility {
        get {
            guard UserDefaults.standard.object(forKey: K.paneControlsVisibility) != nil else { return .hover }
            return PaneControlsVisibility(rawValue: UserDefaults.standard.integer(forKey: K.paneControlsVisibility))
                ?? .hover
        }
        set { set(newValue.rawValue, forKey: K.paneControlsVisibility, topic: .layout) }
    }

    // MARK: - Recording

    /// When true, a pane whose visible terminal is recording gets a red outline.
    var highlightRecordingPane: Bool {
        get { bool(K.highlightRecordingPane, default: true) }
        set { set(newValue, forKey: K.highlightRecordingPane, topic: .layout) }
    }

    var recordingStopAction: RecordingStopAction {
        get {
            guard UserDefaults.standard.object(forKey: K.recordingStopAction) != nil else { return .toast }
            return RecordingStopAction(rawValue: UserDefaults.standard.integer(forKey: K.recordingStopAction))
                ?? .toast
        }
        set { set(newValue.rawValue, forKey: K.recordingStopAction, topic: .layout) }
    }

    /// Where new `.cast` recordings go. Empty means `~/.boo/recordings`.
    var recordingsFolder: String {
        get { UserDefaults.standard.string(forKey: K.recordingsFolder) ?? "" }
        set { set(newValue, forKey: K.recordingsFolder, topic: .layout) }
    }

    /// File name for new recordings; see `SessionRecorder.fileName` for the tokens.
    var recordingFileNameTemplate: String {
        get {
            let raw = UserDefaults.standard.string(forKey: K.recordingFileNameTemplate) ?? ""
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? SessionRecorder.defaultTemplate : raw
        }
        set { set(newValue, forKey: K.recordingFileNameTemplate, topic: .layout) }
    }

    /// Longest pause kept on playback, written as the cast's `idle_time_limit`.
    /// 0 keeps pauses as recorded.
    var recordingIdleTimeLimit: Double {
        get {
            guard UserDefaults.standard.object(forKey: K.recordingIdleTimeLimit) != nil else { return 2 }
            return max(0, UserDefaults.standard.double(forKey: K.recordingIdleTimeLimit))
        }
        set { set(max(0, newValue), forKey: K.recordingIdleTimeLimit, topic: .layout) }
    }

    // MARK: - Tabs

    /// Default content type for new tabs (terminal, browser, etc.).
    var defaultTabType: ContentType {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.defaultTabType) else { return .terminal }
            return ContentType(rawValue: raw) ?? .terminal
        }
        set { set(newValue.rawValue, forKey: K.defaultTabType, topic: .layout) }
    }

    /// When true, auto-detect content type from pasted URLs/file paths.
    var autoDetectContentType: Bool {
        get { bool(K.autoDetectContentType, default: true) }
        set { set(newValue, forKey: K.autoDetectContentType, topic: .layout) }
    }

    /// How to open markdown files from the file tree.
    var markdownOpenMode: MarkdownOpenMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.markdownOpenMode) else { return .preview }
            return MarkdownOpenMode(rawValue: raw) ?? .preview
        }
        set { set(newValue.rawValue, forKey: K.markdownOpenMode, topic: .explorer) }
    }

    // MARK: - Browser

    var linkOpenMode: LinkOpenMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.linkOpenMode) else { return .browserTab }
            return LinkOpenMode(rawValue: raw) ?? .browserTab
        }
        set { set(newValue.rawValue, forKey: K.linkOpenMode, topic: .layout) }
    }

    var browserHomePage: String {
        get { UserDefaults.standard.string(forKey: K.browserHomePage) ?? "https://google.com" }
        set { set(newValue, forKey: K.browserHomePage, topic: .layout) }
    }

    var browserPersistentWebsiteDataEnabled: Bool {
        get { bool(K.browserPersistentWebsiteDataEnabled, default: false) }
        set { set(newValue, forKey: K.browserPersistentWebsiteDataEnabled, topic: .layout) }
    }

    /// When true, closing a browser tab asks first (a page can hold unsent form input).
    var browserConfirmClose: Bool {
        get { bool(K.browserConfirmClose, default: true) }
        set { set(newValue, forKey: K.browserConfirmClose, topic: .layout) }
    }

    var browserHistoryEnabled: Bool {
        get { bool(K.browserHistoryEnabled, default: true) }
        set { set(newValue, forKey: K.browserHistoryEnabled, topic: .layout) }
    }

    /// Maximum number of history entries to keep.
    var browserHistoryLimit: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.browserHistoryLimit)
            return v > 0 ? v : 5000
        }
        set { set(newValue, forKey: K.browserHistoryLimit, topic: .layout) }
    }

    // MARK: - Editor

    var editorFontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.editorFontSize)
            return v > 0 ? CGFloat(v) : 13.0
        }
        set { set(Double(newValue), forKey: K.editorFontSize, topic: .editor) }
    }

    var editorFontName: String {
        get { UserDefaults.standard.string(forKey: K.editorFontName) ?? "SF Mono" }
        set { set(newValue, forKey: K.editorFontName, topic: .editor) }
    }

    func resolvedEditorFont() -> NSFont {
        if let font = NSFont(name: editorFontName, size: editorFontSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    var editorTabSize: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.editorTabSize)
            return v > 0 ? v : 4
        }
        set { set(newValue, forKey: K.editorTabSize, topic: .editor) }
    }

    var editorInsertSpaces: Bool {
        get { bool(K.editorInsertSpaces, default: true) }
        set { set(newValue, forKey: K.editorInsertSpaces, topic: .editor) }
    }

    var editorWordWrap: Bool {
        get { bool(K.editorWordWrap, default: false) }
        set { set(newValue, forKey: K.editorWordWrap, topic: .editor) }
    }

    var editorLineNumbers: Bool {
        get { bool(K.editorLineNumbers, default: true) }
        set { set(newValue, forKey: K.editorLineNumbers, topic: .editor) }
    }

    var editorMinimap: Bool {
        get { bool(K.editorMinimap, default: false) }
        set { set(newValue, forKey: K.editorMinimap, topic: .editor) }
    }

    var editorFormatOnSave: Bool {
        get { bool(K.editorFormatOnSave, default: false) }
        set { set(newValue, forKey: K.editorFormatOnSave, topic: .editor) }
    }

    var editorRulerColumn: Int {
        get { UserDefaults.standard.integer(forKey: K.editorRulerColumn) }
        set { set(newValue, forKey: K.editorRulerColumn, topic: .editor) }
    }

    /// Lets a file's own indentation win over tab size and insert spaces.
    var editorDetectIndentation: Bool {
        get { bool(K.editorDetectIndentation, default: true) }
        set { set(newValue, forKey: K.editorDetectIndentation, topic: .editor) }
    }

    var editorRenderWhitespace: EditorRenderWhitespace {
        get {
            UserDefaults.standard.string(forKey: K.editorRenderWhitespace).flatMap(EditorRenderWhitespace.init)
                ?? .selection
        }
        set { set(newValue.rawValue, forKey: K.editorRenderWhitespace, topic: .editor) }
    }

    var editorBracketPairColors: Bool {
        get { bool(K.editorBracketPairColors, default: true) }
        set { set(newValue, forKey: K.editorBracketPairColors, topic: .editor) }
    }

    var editorStickyScroll: Bool {
        get { bool(K.editorStickyScroll, default: false) }
        set { set(newValue, forKey: K.editorStickyScroll, topic: .editor) }
    }

    var editorFontLigatures: Bool {
        get { bool(K.editorFontLigatures, default: false) }
        set { set(newValue, forKey: K.editorFontLigatures, topic: .editor) }
    }

    var editorCursorStyle: EditorCursorStyle {
        get { UserDefaults.standard.string(forKey: K.editorCursorStyle).flatMap(EditorCursorStyle.init) ?? .line }
        set { set(newValue.rawValue, forKey: K.editorCursorStyle, topic: .editor) }
    }

    var editorCursorBlinking: Bool {
        get { bool(K.editorCursorBlinking, default: true) }
        set { set(newValue, forKey: K.editorCursorBlinking, topic: .editor) }
    }

    var editorAutosave: EditorAutosave {
        get { UserDefaults.standard.string(forKey: K.editorAutosave).flatMap(EditorAutosave.init) ?? .off }
        set { set(newValue.rawValue, forKey: K.editorAutosave, topic: .editor) }
    }

    /// Reload a file changed on disk; asks first when the tab has unsaved edits.
    var editorReloadOnExternalChange: Bool {
        get { bool(K.editorReloadOnExternalChange, default: true) }
        set { set(newValue, forKey: K.editorReloadOnExternalChange, topic: .editor) }
    }

    var editorShowStatusStrip: Bool {
        get { bool(K.editorShowStatusStrip, default: true) }
        set { set(newValue, forKey: K.editorShowStatusStrip, topic: .editor) }
    }

    var editorTrimTrailingWhitespace: Bool {
        get { bool(K.editorTrimTrailingWhitespace, default: false) }
        set { set(newValue, forKey: K.editorTrimTrailingWhitespace, topic: .editor) }
    }

    var editorInsertFinalNewline: Bool {
        get { bool(K.editorInsertFinalNewline, default: false) }
        set { set(newValue, forKey: K.editorInsertFinalNewline, topic: .editor) }
    }

    // MARK: - Notifications

    var activityNotificationsEnabled: Bool {
        get { bool(K.activityNotificationsEnabled, default: true) }
        set { set(newValue, forKey: K.activityNotificationsEnabled, topic: .notifications) }
    }

    /// A finished command notifies only when it ran at least this long. 0 = every command.
    /// Shorter ones still mark the tab's activity dot.
    var notifyMinCommandSeconds: Int {
        get { UserDefaults.standard.object(forKey: K.notifyMinCommandSeconds) as? Int ?? 10 }
        set { set(newValue, forKey: K.notifyMinCommandSeconds, topic: .notifications) }
    }

    /// Fold notifications from one workspace that land within a few seconds into one summary.
    var notificationGroupBursts: Bool {
        get { bool(K.notificationGroupBursts, default: true) }
        set { set(newValue, forKey: K.notificationGroupBursts, topic: .notifications) }
    }

    /// Delivered notifications are removed from Notification Center after this many
    /// minutes. 0 = keep until the tab is focused.
    var notificationExpiryMinutes: Int {
        get { UserDefaults.standard.object(forKey: K.notificationExpiryMinutes) as? Int ?? 15 }
        set { set(newValue, forKey: K.notificationExpiryMinutes, topic: .notifications) }
    }

    /// ntfy-style URL that receives "Push to phone" notices. Empty = off.
    /// Not synced: the topic in it is the only thing guarding the channel.
    var phonePushURL: String {
        get { UserDefaults.standard.string(forKey: K.phonePushURL) ?? "" }
        set { set(newValue.trimmingCharacters(in: .whitespaces), forKey: K.phonePushURL, topic: .notifications) }
    }

    /// A finished command pushes to the phone only when it ran at least this long.
    var phonePushMinCommandSeconds: Int {
        get { UserDefaults.standard.object(forKey: K.phonePushMinCommandSeconds) as? Int ?? 60 }
        set { set(newValue, forKey: K.phonePushMinCommandSeconds, topic: .notifications) }
    }

    // MARK: - Remote Control

    var remoteControlPort: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.remoteControlPort)
            return (v >= 1024 && v <= 65535) ? v : 8899
        }
        set { set(newValue, forKey: K.remoteControlPort) }
    }

    // MARK: - Onboarding

    /// Set once the first-launch welcome window has had its chance. Local
    /// only: a synced second Mac is still a first launch there.
    var welcomeShown: Bool {
        get { UserDefaults.standard.bool(forKey: K.welcomeShown) }
        set { UserDefaults.standard.set(newValue, forKey: K.welcomeShown) }
    }

    // MARK: - Scrollback

    /// Save terminal scrollback on quit and replay it into restored tabs.
    var restoreScrollback: Bool {
        get { bool(K.restoreScrollback, default: true) }
        set { set(newValue, forKey: K.restoreScrollback) }
    }

    /// Show `tmux -CC` sessions as native workspaces and panes. Off leaves
    /// Ghostty's own control-mode handling. Applies to terminals opened afterwards.
    var tmuxIntegration: Bool {
        get { bool(K.tmuxIntegration, default: true) }
        set { set(newValue, forKey: K.tmuxIntegration) }
    }

    // MARK: - Shortcuts

    /// Menu item id ("Terminal/Split Right") → shortcut spec ("cmd+shift+d");
    /// an empty spec removes the item's shortcut. See `ShortcutOverrides`.
    var shortcutOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: K.shortcutOverrides) as? [String: String] ?? [:] }
        set { set(newValue, forKey: K.shortcutOverrides, topic: .shortcuts) }
    }

    // MARK: - Secure Keyboard Entry

    /// Process-wide, like Terminal's: other apps can't observe keystrokes while Boo is frontmost.
    var secureKeyboardEntry: Bool {
        get { bool(K.secureKeyboardEntry, default: false) }
        set { set(newValue, forKey: K.secureKeyboardEntry) }
    }

    // MARK: - Command Palette

    /// Palette item ids, most recent pick first. Not in settings.json and not
    /// broadcast: it changes on every pick and nothing observes it.
    var paletteRecents: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.paletteRecents) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(PaletteRanker.recentLimit)), forKey: K.paletteRecents) }
    }

    // MARK: - Plugins

    var disabledPluginIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.disabledPluginIDs) ?? [] }
        set {
            _disabledPluginIDsSet = nil
            set(newValue, forKey: K.disabledPluginIDs, topic: .plugins)
        }
    }

    private var _disabledPluginIDsSet: Set<String>?

    /// Cached Set for O(1) lookups — invalidated on write.
    var disabledPluginIDsSet: Set<String> {
        if let cached = _disabledPluginIDsSet { return cached }
        let result = Set(disabledPluginIDs)
        _disabledPluginIDsSet = result
        return result
    }

    /// Whether a plugin is currently enabled (not in the disabled list).
    func isPluginEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDsSet.contains(pluginID)
    }

    /// Plugins open in the sidebar by default when opening a new pane or starting the app.
    /// Saved tab order for the sidebar tab bar (plugin IDs in display order).
    var sidebarTabOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: K.sidebarPluginOrder) ?? [] }
        set { set(newValue, forKey: K.sidebarPluginOrder) }
    }

    // MARK: - Sidebar State Persistence

    /// Persisted section heights per section ID. Survives app restart.
    var sidebarSectionHeights: [String: CGFloat] {
        guard let dict = pluginSettingsDict["__sidebar"]?["sectionHeights"] as? [String: Double] else {
            return [:]
        }
        return dict.mapValues { CGFloat($0) }
    }

    /// Persisted section order per plugin ID. Survives app restart.
    var sidebarSectionOrder: [String: [String]] {
        pluginSettingsDict["__sidebar"]?["sectionOrder"] as? [String: [String]] ?? [:]
    }

    /// Persisted expanded section IDs for global sidebar state.
    var sidebarGlobalExpandedSectionIDs: Set<String> {
        Set(pluginSettingsDict["__sidebar"]?["globalExpandedSectionIDs"] as? [String] ?? [])
    }

    /// Persisted explicitly-collapsed section IDs for global sidebar state.
    var sidebarGlobalUserCollapsedSectionIDs: Set<String> {
        Set(pluginSettingsDict["__sidebar"]?["globalUserCollapsedSectionIDs"] as? [String] ?? [])
    }

    /// Persisted selected plugin tab for global sidebar state.
    var sidebarGlobalSelectedPluginTabID: String? {
        pluginSettingsDict["__sidebar"]?["globalSelectedPluginTabID"] as? String
    }

    /// Persisted scroll offsets for global sidebar state.
    var sidebarGlobalScrollOffsets: [String: CGPoint] {
        guard let dict = pluginSettingsDict["__sidebar"]?["globalScrollOffsets"] as? [String: [Double]] else {
            return [:]
        }
        return dict.compactMapValues { values in
            guard values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
    }

    /// Write both sidebar state keys in one dict mutation + one disk write.
    func saveSidebarState(
        heights: [String: CGFloat],
        order: [String: [String]],
        globalExpandedSectionIDs: Set<String>? = nil,
        globalUserCollapsedSectionIDs: Set<String>? = nil,
        globalSelectedPluginTabID: String? = nil,
        globalScrollOffsets: [String: CGPoint]? = nil
    ) {
        var sidebarDict = pluginSettingsDict["__sidebar"] ?? [:]
        sidebarDict["sectionHeights"] = heights.mapValues { Double($0) }
        sidebarDict["sectionOrder"] = order
        if let globalExpandedSectionIDs {
            sidebarDict["globalExpandedSectionIDs"] = Array(globalExpandedSectionIDs)
        }
        if let globalUserCollapsedSectionIDs {
            sidebarDict["globalUserCollapsedSectionIDs"] = Array(globalUserCollapsedSectionIDs)
        }
        if let globalSelectedPluginTabID {
            sidebarDict["globalSelectedPluginTabID"] = globalSelectedPluginTabID
        }
        if let globalScrollOffsets {
            sidebarDict["globalScrollOffsets"] = globalScrollOffsets.mapValues { [Double($0.x), Double($0.y)] }
        }
        var all = pluginSettingsDict
        all["__sidebar"] = sidebarDict
        pluginSettingsDict = all
        saveToFile()
    }

    /// nil = never asked, true = user approved, false = user declined.
    var sshControlMasterApproved: Bool? {
        get {
            UserDefaults.standard.object(forKey: K.sshControlMasterApproved) == nil
                ? nil : UserDefaults.standard.bool(forKey: K.sshControlMasterApproved)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: K.sshControlMasterApproved)
            saveToFile()
        }
    }

    // MARK: - Plugin Settings

    private var _pluginSettingsDict: [String: [String: Any]]?

    /// Cached — plugins read settings on every sidebar cycle, and bridging the whole
    /// UserDefaults dictionary per read adds up. Invalidated on write.
    private var pluginSettingsDict: [String: [String: Any]] {
        get {
            if let cached = _pluginSettingsDict { return cached }
            let dict = UserDefaults.standard.dictionary(forKey: K.pluginSettings) as? [String: [String: Any]] ?? [:]
            _pluginSettingsDict = dict
            return dict
        }
        set {
            UserDefaults.standard.set(newValue, forKey: K.pluginSettings)
            _pluginSettingsDict = newValue
        }
    }

    /// Drop the cached plugin settings after the defaults key was written directly.
    func reloadPluginSettings() {
        _pluginSettingsDict = nil
    }

    func pluginSetting<T>(_ pluginID: String, _ key: String, default defaultValue: T) -> T {
        guard let dict = pluginSettingsDict[pluginID], let val = dict[key] as? T else { return defaultValue }
        return val
    }

    func pluginBool(_ pluginID: String, _ key: String, default defaultValue: Bool) -> Bool {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func pluginString(_ pluginID: String, _ key: String, default defaultValue: String) -> String {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func pluginDouble(_ pluginID: String, _ key: String, default defaultValue: Double) -> Double {
        pluginSetting(pluginID, key, default: defaultValue)
    }

    func setPluginSetting(_ pluginID: String, _ key: String, _ value: Any, topic: SettingsTopic? = .plugins) {
        var all = pluginSettingsDict
        var plugin = all[pluginID] ?? [:]
        plugin[key] = value
        all[pluginID] = plugin
        pluginSettingsDict = all
        saveToFile()
        notify(topic: topic)
    }

    /// Returns the full settings dictionary for a given plugin ID.
    func pluginSettingsDict(for pluginID: String) -> [String: Any] {
        pluginSettingsDict[pluginID] ?? [:]
    }

    /// Replaces the full settings dictionary for a given plugin ID.
    func setPluginSettingsDict(_ dict: [String: Any], for pluginID: String) {
        var all = pluginSettingsDict
        all[pluginID] = dict
        pluginSettingsDict = all
        saveToFile()
    }

    func migratePluginIdentity(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        var didChange = false

        var all = pluginSettingsDict
        if all[newID] == nil, let oldSettings = all[oldID] {
            all[newID] = oldSettings
            didChange = true
        }

        if var sidebar = all["__sidebar"] {
            if var order = sidebar["sectionOrder"] as? [String: [String]],
                order[newID] == nil,
                let oldOrder = order[oldID]
            {
                order[newID] = oldOrder
                order.removeValue(forKey: oldID)
                sidebar["sectionOrder"] = order
                didChange = true
            }
            if sidebar["globalSelectedPluginTabID"] as? String == oldID {
                sidebar["globalSelectedPluginTabID"] = newID
                didChange = true
            }
            all["__sidebar"] = sidebar
        }

        if didChange {
            pluginSettingsDict = all
        }

        let migratedOrder = sidebarTabOrder.map { $0 == oldID ? newID : $0 }
        if migratedOrder != sidebarTabOrder {
            var seen = Set<String>()
            sidebarTabOrder = migratedOrder.filter { seen.insert($0).inserted }
            didChange = true
        }

        var disabled = disabledPluginIDs
        if disabled.contains(oldID) {
            disabled.removeAll { $0 == oldID || $0 == newID }
            disabled.append(newID)
            disabledPluginIDs = disabled
            didChange = true
        }

        if didChange {
            saveToFile()
            notify(topic: .plugins)
        }
    }

    static var availableMonospaceFonts: [String] {
        let fm = NSFontManager.shared
        var fonts = Set<String>(["SF Mono"])
        for family in fm.availableFontFamilies {
            if let members = fm.availableMembers(ofFontFamily: family),
                let first = members.first,
                let traits = first[3] as? UInt,
                (traits & UInt(NSFontTraitMask.fixedPitchFontMask.rawValue)) != 0
            {
                fonts.insert(family)
            }
        }
        let knownMono = [
            "Menlo", "Monaco", "Courier", "Courier New", "Fira Code", "JetBrains Mono", "Hack", "Source Code Pro",
            "Inconsolata"
        ]
        for name in knownMono where NSFont(name: name, size: 14) != nil {
            fonts.insert(name)
        }
        return fonts.sorted()
    }

    static var availableSystemFonts: [String] {
        var result = ["System Default"]
        result.append(contentsOf: NSFontManager.shared.availableFontFamilies.sorted())
        return result
    }

    private func notify(topic: SettingsTopic? = nil) {
        NotificationCenter.default.post(
            name: .settingsChanged,
            object: nil,
            userInfo: topic.map { ["topic": $0.rawValue] }
        )
    }

    // MARK: - File Persistence (~/.boo/settings.json)

    /// Everything `settings.json` holds, as stored in UserDefaults.
    private func fileDictionary() -> [String: Any] {
        var dict: [String: Any] = [
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
            K.statusBarShowPorts: statusBarShowPorts,
            K.statusBarShowShell: statusBarShowShell,
            K.statusBarShowConnection: statusBarShowConnection,
            K.sidebarPosition: sidebarPosition.rawValue,
            K.workspaceBarPosition: workspaceBarPosition.rawValue,
            K.defaultFolder: defaultFolder,
            K.defaultMainPage: defaultMainPage,
            K.sidebarWidth: Double(sidebarWidth),
            K.sidebarDefaultHidden: sidebarDefaultHidden,
            K.tabOverflowMode: tabOverflowMode.rawValue,
            K.defaultTabType: defaultTabType.rawValue,
            K.autoDetectContentType: autoDetectContentType,
            K.browserHomePage: browserHomePage,
            K.browserPersistentWebsiteDataEnabled: browserPersistentWebsiteDataEnabled,
            K.browserConfirmClose: browserConfirmClose,
            K.linkOpenMode: linkOpenMode.rawValue,
            K.disabledPluginIDs: disabledPluginIDs,
            K.sidebarPluginOrder: sidebarTabOrder,
            K.pluginSettings: pluginSettingsDict,
            K.sidebarFontSize: Double(sidebarFontSize),
            K.sidebarFontName: sidebarFontName,
            K.fileEditorCommand: fileEditorCommand,
            K.sidebarTabBarPosition: sidebarTabBarPosition.rawValue,
            K.sidebarGlobalState: sidebarGlobalState,
            K.sidebarPerWorkspaceState: sidebarPerWorkspaceState,
            K.autoColorWorkspaces: autoColorWorkspaces,
            K.openWorkspaceEditorOnCreate: openWorkspaceEditorOnCreate,
            K.openGroupEditorOnCreate: openGroupEditorOnCreate,
            K.newTabsJoinActiveGroup: newTabsJoinActiveGroup,
            K.paneControlsVisibility: paneControlsVisibility.rawValue,
            K.highlightRecordingPane: highlightRecordingPane,
            K.recordingStopAction: recordingStopAction.rawValue,
            K.recordingsFolder: recordingsFolder,
            K.recordingFileNameTemplate: recordingFileNameTemplate,
            K.recordingIdleTimeLimit: recordingIdleTimeLimit,
            K.editorFontSize: Double(editorFontSize),
            K.editorFontName: editorFontName,
            K.editorTabSize: editorTabSize,
            K.editorInsertSpaces: editorInsertSpaces,
            K.editorWordWrap: editorWordWrap,
            K.editorLineNumbers: editorLineNumbers,
            K.editorMinimap: editorMinimap,
            K.editorFormatOnSave: editorFormatOnSave,
            K.editorRulerColumn: editorRulerColumn,
            K.editorDetectIndentation: editorDetectIndentation,
            K.editorRenderWhitespace: editorRenderWhitespace.rawValue,
            K.editorBracketPairColors: editorBracketPairColors,
            K.editorStickyScroll: editorStickyScroll,
            K.editorFontLigatures: editorFontLigatures,
            K.editorCursorStyle: editorCursorStyle.rawValue,
            K.editorCursorBlinking: editorCursorBlinking,
            K.editorAutosave: editorAutosave.rawValue,
            K.editorReloadOnExternalChange: editorReloadOnExternalChange,
            K.editorShowStatusStrip: editorShowStatusStrip,
            K.editorTrimTrailingWhitespace: editorTrimTrailingWhitespace,
            K.editorInsertFinalNewline: editorInsertFinalNewline,
            K.quickTerminalEnabled: quickTerminalEnabled,
            K.quickTerminalHotkey: quickTerminalHotkey,
            K.quickTerminalHeight: quickTerminalHeight,
            K.quickTerminalHideOnResign: quickTerminalHideOnResign,
            K.defaultProfile: defaultProfile ?? "",
            K.terminalShader: terminalShader,
            K.defaultLinkTarget: defaultLinkTarget.rawValue,
            K.externalEditorPreset: externalEditorPreset.rawValue,
            K.externalEditorTemplate: externalEditorTemplate,
            K.historyEnabled: historyEnabled,
            K.historyIgnorePattern: historyIgnorePattern,
            K.historyRetentionDays: historyRetentionDays,
            K.historySearchShortcutEnabled: historySearchShortcutEnabled,
            K.syncFolder: syncFolder,
            K.agentBudgetPerTask: agentBudgetPerTask ?? 0,
            K.agentBudgetPerDay: agentBudgetPerDay ?? 0,
            K.portNotificationsEnabled: portNotificationsEnabled,
            K.errorAgentButtonEnabled: errorAgentButtonEnabled,
            K.notifyMinCommandSeconds: notifyMinCommandSeconds,
            K.notificationGroupBursts: notificationGroupBursts,
            K.notificationExpiryMinutes: notificationExpiryMinutes,
            K.restoreScrollback: restoreScrollback,
            K.tmuxIntegration: tmuxIntegration,
            K.shortcutOverrides: shortcutOverrides
        ]
        if let sshControlMasterApproved {
            dict[K.sshControlMasterApproved] = sshControlMasterApproved
        }
        return dict
    }

    private func saveToFile() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: fileDictionary(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: BooPaths.settingsFile))
        } catch {
            debugLog("[Settings] Failed to save: \(error)")
            if !saveErrorShown {
                saveErrorShown = true
                DispatchQueue.main.async {
                    BooAlert.showTransient("Settings could not be saved")
                }
            }
        }
    }

    private func loadFromFile() {
        let path = BooPaths.settingsFile
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
        // On first launch, load settings from ~/.boo/settings.json if it exists
        loadFromFile()
        // Ensure the config directory exists
        _ = BooPaths.configDir
        migratePluginSettings()
        applyDefaultOffPlugins()
    }

    /// Built-in plugins that start disabled. Each is disabled once, so a
    /// user who enables one keeps it enabled.
    static let defaultOffPluginIDs = ["kube"]

    private func applyDefaultOffPlugins() {
        let applied = Set(UserDefaults.standard.stringArray(forKey: K.defaultOffPluginsApplied) ?? [])
        let pending = Self.defaultOffPluginIDs.filter { !applied.contains($0) }
        guard !pending.isEmpty else { return }
        var disabled = disabledPluginIDs
        for id in pending where !disabled.contains(id) { disabled.append(id) }
        // Still inside init: no change notification (observers would re-enter `shared`).
        UserDefaults.standard.set(disabled, forKey: K.disabledPluginIDs)
        _disabledPluginIDsSet = nil
        UserDefaults.standard.set(Array(applied) + pending, forKey: K.defaultOffPluginsApplied)
        saveToFile()
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
        if !ft.isEmpty { all["file-tree-local"] = ft }

        pluginSettingsDict = all
        UserDefaults.standard.set(true, forKey: K.migratedPluginSettings_v1)
        saveToFile()
    }
}

/// Observable wrapper so SwiftUI views re-render when settings change.
/// Pass `topics` to limit re-renders to only the settings categories the view cares about.
/// An empty `topics` set (the default) matches all changes (backward-compatible).
@MainActor final class SettingsObserver: ObservableObject {
    @Published var revision: Int = 0
    nonisolated(unsafe) private var observer: Any?
    private let topics: Set<SettingsTopic>

    init(topics: Set<SettingsTopic> = []) {
        self.topics = topics
        observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let topicRaw = notification.userInfo?["topic"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.topics.isEmpty,
                    let topicRaw,
                    let topic = SettingsTopic(rawValue: topicRaw),
                    !self.topics.contains(topic)
                {
                    return
                }
                self.revision += 1
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Editor option values

/// Raw values are Monaco's `renderWhitespace` values.
enum EditorRenderWhitespace: String, CaseIterable, Sendable {
    case none, boundary, selection, trailing, all

    var displayName: String {
        switch self {
        case .none: return "Never"
        case .boundary: return "Between words"
        case .selection: return "In selection"
        case .trailing: return "Trailing"
        case .all: return "Always"
        }
    }
}

/// Raw values are Monaco's `cursorStyle` values.
enum EditorCursorStyle: String, CaseIterable, Sendable {
    case line, block, underline

    var displayName: String {
        switch self {
        case .line: return "Bar"
        case .block: return "Block"
        case .underline: return "Underline"
        }
    }
}

enum EditorAutosave: String, CaseIterable, Sendable {
    case off, afterDelay, onFocusChange

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .afterDelay: return "After a short delay"
        case .onFocusChange: return "When the editor loses focus"
        }
    }
}
