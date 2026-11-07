import Cocoa
import SwiftUI

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
    case statusBar  // status bar segments: visibility, order, sides, appearance
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
    case workspaceGroups  // named, collapsible groups of workspaces
}
final class AppSettings {
    nonisolated(unsafe) static let shared = AppSettings()

    /// Show save-error feedback only once per session to avoid spam.
    var saveErrorShown = false

    // MARK: - Keys

    enum K {
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
        static let statusBarLeftOrder = "statusBarLeftOrder"
        static let statusBarRightOrder = "statusBarRightOrder"
        static let statusBarHiddenSegments = "statusBarHiddenSegments"
        static let statusBarClockFormat = "statusBarClockFormat"
        static let statusBarPathStyle = "statusBarPathStyle"
        static let statusBarBranchMaxLength = "statusBarBranchMaxLength"
        static let statusBarSeparators = "statusBarSeparators"
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
        static let agentJumpHotkey = "agentJumpHotkey"
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
        static let agentCostTracking = "agentCostTracking"
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
        static let workspaceGroups = "workspaceGroups"
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
        static let agentBrowserAccessEnabled = "agentBrowserAccessEnabled"

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

        static let remoteControlPort = "remoteControlPort"
        static let secureKeyboardEntry = "secureKeyboardEntry"
        static let restoreScrollback = "restoreScrollback"
        static let tmuxIntegration = "tmuxIntegration"
        static let tmuxMode = "tmuxMode"
        static let shortcutOverrides = "shortcutOverrides"

        static let paletteRecents = "paletteRecents"
    }

    /// Bool from UserDefaults with a custom default (since .bool returns false for unset keys).
    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
    }

    func set(_ value: Any?, forKey key: String, topic: SettingsTopic? = nil) {
        UserDefaults.standard.set(value, forKey: key)
        saveToFile()
        notify(topic: topic)
    }

    /// Transient theme override shown while the custom-theme editor is open —
    /// the whole UI restyles live as colors are picked. Never persisted;
    /// cleared (nil) when the editor saves or cancels.
    var previewTheme: TerminalTheme? {
        didSet { notify(topic: .theme) }
    }

    /// Last resolved custom theme, keyed by name and the raw stored bytes.
    /// `theme` is read from every draw(); decoding all custom themes from JSON
    /// each time was measurable. Keying on the stored Data (not a notification)
    /// keeps the cache correct for any writer of the defaults key.
    var customThemeCache: (name: String, data: Data?, theme: TerminalTheme)?
    let customThemeCacheLock = NSLock()

    var _disabledPluginIDsSet: Set<String>?

    var _pluginSettingsDict: [String: [String: Any]]?

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

    /// Pin the open parent folders of the rows in view to the top of the tree.
    var explorerStickyFolders: Bool { pluginBool("file-tree-local", "stickyFolders", default: true) }

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

    /// The global hotkey that jumps to the next agent needing the user; empty is off.
    var agentJumpHotkey: String {
        get { UserDefaults.standard.string(forKey: K.agentJumpHotkey) ?? "" }
        set { set(newValue, forKey: K.agentJumpHotkey) }
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
        get { UserDefaults.standard.string(forKey: K.defaultLinkTarget).flatMap(LinkTarget.init) ?? .editor }
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

    // MARK: - Agents

    /// Read Claude Code transcripts for cost estimates (status, timeline, the
    /// summary in Settings and budgets). Off by default: the first scan reads
    /// every transcript of the last 30 days.
    var agentCostTracking: Bool {
        get { bool(K.agentCostTracking, default: false) }
        set { set(newValue, forKey: K.agentCostTracking, topic: .agents) }
    }

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

    var paneControlsVisibility: PaneControlsVisibility {
        get {
            guard UserDefaults.standard.object(forKey: K.paneControlsVisibility) != nil else { return .hover }
            return PaneControlsVisibility(rawValue: UserDefaults.standard.integer(forKey: K.paneControlsVisibility))
                ?? .hover
        }
        set { set(newValue.rawValue, forKey: K.paneControlsVisibility, topic: .layout) }
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

    /// What a plain `tmux` typed in a Boo shell does: switch to control mode
    /// (`always`), ask first (`ask`), or run tmux as usual (`never`).
    /// Read by the shell integration's `tmux` wrapper via `boo tmux mode`.
    var tmuxMode: TmuxMode {
        get {
            guard tmuxIntegration else { return .never }
            return UserDefaults.standard.string(forKey: K.tmuxMode).flatMap(TmuxMode.init(rawValue:)) ?? .ask
        }
        set { set(newValue.rawValue, forKey: K.tmuxMode) }
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

    func notify(topic: SettingsTopic? = nil) {
        NotificationCenter.default.post(
            name: .settingsChanged,
            object: nil,
            userInfo: topic.map { ["topic": $0.rawValue] }
        )
    }

    private init() {
        // On first launch, load settings from ~/.boo/settings.json if it exists
        loadFromFile()
        // Ensure the config directory exists
        _ = BooPaths.configDir
        migratePluginSettings()
        applyDefaultOffPlugins()
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

/// See `AppSettings.tmuxMode`.
enum TmuxMode: String, CaseIterable {
    case always, ask, never

    var label: String {
        switch self {
        case .always: "Always"
        case .ask: "Ask"
        case .never: "Never"
        }
    }
}
