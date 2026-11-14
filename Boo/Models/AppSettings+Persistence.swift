import Cocoa

extension AppSettings {
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
        K.statusBarShowConnection, K.statusBarLeftOrder, K.statusBarRightOrder, K.statusBarHiddenSegments,
        K.statusBarClockFormat, K.statusBarPathStyle, K.statusBarBranchMaxLength, K.statusBarSeparators,
        K.sidebarPosition, K.workspaceBarPosition,
        K.sidebarDefaultHidden, K.tabOverflowMode, K.undoCloseSeconds, K.defaultTabType, K.autoDetectContentType,
        K.browserHomePage,
        K.browserConfirmClose, K.agentBrowserAccessEnabled, K.linkOpenMode, K.disabledPluginIDs, K.sidebarPluginOrder,
        K.pluginSettings,
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
        K.agentJumpHotkey,
        K.defaultProfile, K.terminalShader, K.defaultLinkTarget, K.externalEditorPreset, K.historyEnabled,
        K.historyIgnorePattern, K.historyRetentionDays, K.historySearchShortcutEnabled, K.agentCostTracking,
        K.agentBudgetPerTask,
        K.agentBudgetPerDay, K.portNotificationsEnabled, K.errorAgentButtonEnabled, K.notifyMinCommandSeconds,
        K.notificationGroupBursts, K.notificationExpiryMinutes, K.shortcutOverrides, K.agentRecovery,
        K.resumeAgentsAfterQuit, K.appIcon, K.resumeAgentsImmediately, K.continueInterruptedAgents
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
            K.statusBarShowConnection: statusBarShowConnection,
            K.statusBarLeftOrder: statusBarLeftOrder,
            K.statusBarRightOrder: statusBarRightOrder,
            K.statusBarHiddenSegments: statusBarHiddenSegments,
            K.statusBarClockFormat: statusBarClockFormat.rawValue,
            K.statusBarPathStyle: statusBarPathStyle.rawValue,
            K.statusBarBranchMaxLength: statusBarBranchMaxLength,
            K.statusBarSeparators: statusBarSeparators,
            K.sidebarPosition: sidebarPosition.rawValue,
            K.workspaceBarPosition: workspaceBarPosition.rawValue,
            K.defaultFolder: defaultFolder,
            K.defaultMainPage: defaultMainPage,
            K.sidebarWidth: Double(sidebarWidth),
            K.sidebarDefaultHidden: sidebarDefaultHidden,
            K.tabOverflowMode: tabOverflowMode.rawValue,
            K.undoCloseSeconds: undoCloseSeconds,
            K.defaultTabType: defaultTabType.rawValue,
            K.autoDetectContentType: autoDetectContentType,
            K.browserHomePage: browserHomePage,
            K.browserPersistentWebsiteDataEnabled: browserPersistentWebsiteDataEnabled,
            K.browserConfirmClose: browserConfirmClose,
            K.agentBrowserAccessEnabled: agentBrowserAccessEnabled,
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
            K.sidebarStateScope: sidebarStateScope.rawValue,
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
            K.agentJumpHotkey: agentJumpHotkey,
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
            K.agentCostTracking: agentCostTracking,
            K.agentBudgetPerTask: agentBudgetPerTask ?? 0,
            K.agentBudgetPerDay: agentBudgetPerDay ?? 0,
            K.portNotificationsEnabled: portNotificationsEnabled,
            K.errorAgentButtonEnabled: errorAgentButtonEnabled,
            K.notifyMinCommandSeconds: notifyMinCommandSeconds,
            K.notificationGroupBursts: notificationGroupBursts,
            K.notificationExpiryMinutes: notificationExpiryMinutes,
            K.restoreScrollback: restoreScrollback,
            K.tmuxIntegration: tmuxIntegration,
            K.tmuxMode: UserDefaults.standard.string(forKey: K.tmuxMode) ?? TmuxMode.ask.rawValue,
            K.tmuxHistoryLines: tmuxHistoryLines,
            K.tmuxPauseAfterSeconds: tmuxPauseAfterSeconds,
            K.tmuxAutoUnpause: tmuxAutoUnpause,
            K.tmuxExternalWindowsInBackground: tmuxExternalWindowsInBackground,
            K.tmuxAttachWindowLimit: tmuxAttachWindowLimit,
            K.tmuxMirrorPasteBuffer: tmuxMirrorPasteBuffer,
            K.tmuxReattachOnLaunch: tmuxReattachOnLaunch,
            K.agentRecovery: agentRecovery.rawValue,
            K.appIcon: appIcon.rawValue,
            K.resumeAgentsAfterQuit: resumeAgentsAfterQuit,
            K.resumeAgentsImmediately: resumeAgentsImmediately,
            K.continueInterruptedAgents: continueInterruptedAgents,
            K.shortcutOverrides: shortcutOverrides,
            K.workspaceGroups: workspaceGroups.map(\.dictionary)
        ]
        if let sshControlMasterApproved {
            dict[K.sshControlMasterApproved] = sshControlMasterApproved
        }
        return dict
    }

    func saveToFile() {
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

    func loadFromFile() {
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

    /// Built-in plugins that start disabled. Each is disabled once, so a
    /// user who enables one keeps it enabled.
    static let defaultOffPluginIDs = ["kube", "1password"]

    func applyDefaultOffPlugins() {
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

    func migratePluginSettings() {
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
