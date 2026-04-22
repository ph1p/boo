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

    var label: String {
        switch self {
        case .scroll: return "Scroll"
        case .wrap: return "Wrap"
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

enum MarkdownOpenMode: String, CaseIterable, Codable {
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

enum ImageOpenMode: String, CaseIterable, Codable {
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

enum TextOpenMode: String, CaseIterable, Codable {
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
        static let pluginSettings = "pluginSettings"
        static let migratedPluginSettings_v1 = "migratedPluginSettings_v1"
        static let fileEditorCommand = "fileEditorCommand"

        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skipVersion = "skipVersion"
        static let sidebarDefaultHidden = "sidebarDefaultHidden"
        static let defaultFolder = "defaultFolder"
        static let defaultMainPage = "defaultMainPage"
        static let sshControlMasterApproved = "sshControlMasterApproved"
        static let customThemes = "customThemes"
        static let newTabCwdMode = "newTabCwdMode"
        static let activeSidebarTab = "activeSidebarTab"
        static let sidebarTabBarPosition = "sidebarTabBarPosition"
        static let sidebarGlobalState = "sidebarGlobalState"
        static let sidebarPerWorkspaceState = "sidebarPerWorkspaceState"
        static let defaultTabType = "defaultTabType"
        static let autoDetectContentType = "autoDetectContentType"
        static let markdownOpenMode = "markdownOpenMode"
        static let linkOpenMode = "linkOpenMode"
        static let browserHomePage = "browserHomePage"
        static let browserPersistentWebsiteDataEnabled = "browserPersistentWebsiteDataEnabled"
        static let browserHistoryEnabled = "browserHistoryEnabled"
        static let browserHistoryLimit = "browserHistoryLimit"

        static let editorFontSize = "editorFontSize"
        static let editorFontName = "editorFontName"
        static let editorTabSize = "editorTabSize"
        static let editorInsertSpaces = "editorInsertSpaces"
        static let editorWordWrap = "editorWordWrap"
        static let editorLineNumbers = "editorLineNumbers"
        static let editorMinimap = "editorMinimap"
        static let editorFormatOnSave = "editorFormatOnSave"
        static let editorRulerColumn = "editorRulerColumn"
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

    var theme: TerminalTheme {
        if let t = Self.builtInThemesByName[themeName] { return t }
        return customThemes.first(where: { $0.name == themeName })?.toTheme() ?? .defaultDark
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

    /// When true, the sidebar starts hidden in new windows.
    var sidebarDefaultHidden: Bool {
        get { bool(K.sidebarDefaultHidden, default: false) }
        set { set(newValue, forKey: K.sidebarDefaultHidden, topic: .layout) }
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

    // MARK: - Updates

    var autoCheckUpdates: Bool {
        get { bool(K.autoCheckUpdates, default: true) }
        set {
            UserDefaults.standard.set(newValue, forKey: K.autoCheckUpdates)
            saveToFile()
        }
    }

    var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: K.lastUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: K.lastUpdateCheck) }
    }

    var skipVersion: String? {
        get { UserDefaults.standard.string(forKey: K.skipVersion) }
        set {
            UserDefaults.standard.set(newValue, forKey: K.skipVersion)
            saveToFile()
        }
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

    private var pluginSettingsDict: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: K.pluginSettings) as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: K.pluginSettings) }
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

    private func saveToFile() {
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
            K.editorFontSize: Double(editorFontSize),
            K.editorFontName: editorFontName,
            K.editorTabSize: editorTabSize,
            K.editorInsertSpaces: editorInsertSpaces,
            K.editorWordWrap: editorWordWrap,
            K.editorLineNumbers: editorLineNumbers,
            K.editorMinimap: editorMinimap,
            K.editorFormatOnSave: editorFormatOnSave,
            K.editorRulerColumn: editorRulerColumn
        ]
        dict[K.autoCheckUpdates] = autoCheckUpdates
        if let skipVersion {
            dict[K.skipVersion] = skipVersion
        }
        if let sshControlMasterApproved {
            dict[K.sshControlMasterApproved] = sshControlMasterApproved
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
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
