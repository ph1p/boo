import Cocoa

// MARK: - Actions

extension MainWindowController {
    func handleGhosttyAction(_ action: String, userInfo: [String: String]) {
        switch action {
        case "new_split":
            let dirStr = userInfo["direction"] ?? "vertical"
            if dirStr == "horizontal" {
                splitHorizontalAction(nil)
            } else {
                splitVerticalAction(nil)
            }

        case "goto_split":
            switch userInfo["direction"] ?? "next" {
            case "next": focusNextPaneAction(nil)
            case "previous": focusPrevPaneAction(nil)
            case let name:
                if let dir = PaneDirection(name: name) { focusPane(dir) }
            }

        case "resize_split":
            guard let dir = PaneDirection(name: userInfo["direction"] ?? "") else { return }
            resizeActivePane(toward: dir, by: CGFloat(Double(userInfo["amount"] ?? "") ?? 10))

        case "toggle_split_zoom":
            toggleZoomPaneAction(nil)

        case "equalize_splits":
            equalizeSplitsAction(nil)

        case "close_surface":
            smartCloseAction(nil)

        case "new_tab":
            newTabAction(nil)

        case "new_workspace":
            newWorkspaceAction(nil)

        case "new_window":
            newWindowAction(nil)

        case "toggle_fullscreen":
            window?.toggleFullScreen(nil)

        case "close_window":
            window?.close()

        case "open_settings":
            showSettingsAction(nil)

        default:
            break
        }
    }

    @objc func newWorkspaceAction(_ sender: Any?) {
        openWorkspace(path: AppSettings.shared.defaultFolder)
        guard AppSettings.shared.openWorkspaceEditorOnCreate else { return }
        // The new pill only exists once the debounced toolbar refresh runs; flush it.
        refreshToolbarNow()
        showActiveWorkspaceEditor()
    }

    @objc func newWindowAction(_ sender: Any?) {
        WindowManager.shared.newWindow()
    }

    @objc func openFolderAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open as a workspace"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            FolderBookmarkStore.shared.save(url)
            self?.openWorkspace(path: url.path)
        }
    }

    @objc func newTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let cwd = newTabWorkingDirectory(in: workspace)
        pv.addNewTab(workingDirectory: cwd, group: pv.activeGroupID)
        saveSession()
    }

    @objc func newBrowserTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        pv.addNewTab(contentType: .browser, url: ContentType.newTabURL, group: pv.activeGroupID)
        saveSession()
    }

    /// Working directory for a new tab: the active tab's, or the workspace folder,
    /// depending on `newTabCwdMode`.
    private func newTabWorkingDirectory(in workspace: Workspace) -> String {
        if AppSettings.shared.newTabCwdMode == .samePath,
            let activeCwd = workspace.pane(for: workspace.activePaneID)?.activeTab?.workingDirectory
        {
            return activeCwd
        }
        return workspace.folderPath
    }

    /// Open a new tab of the specified content type (used by context menus).
    @objc func newTabOfType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType,
            let workspace = activeWorkspace,
            workspace.pane(for: workspace.activePaneID) != nil,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let cwd = newTabWorkingDirectory(in: workspace)
        pv.addNewTab(contentType: type, workingDirectory: cwd, group: pv.activeGroupID)
        saveSession()
    }

    /// Re-reads shader files and ~/.boo/ghostty-user.conf after editing them; Ghostty compiles on config push.
    @objc func reloadShadersAction(_ sender: Any?) {
        GhosttyRuntime.shared.reloadConfig()
    }

    @objc func splitVerticalAction(_ sender: Any?) {
        splitActivePane(direction: .horizontal)
    }

    @objc func splitHorizontalAction(_ sender: Any?) {
        splitActivePane(direction: .vertical)
    }

    @objc func showSettingsAction(_ sender: Any?) {
        PluginSettingsView.registeredManifests = pluginRegistry.plugins.map(\.manifest)
        SettingsWindowController.shared.showSettings()
    }

    @objc func showAboutAction(_ sender: Any?) {
        AboutWindowController.shared.showAbout()
    }

    @objc func showWelcomeAction(_ sender: Any?) {
        WelcomeWindowController.shared.showWelcome()
    }

    @objc func openDocumentationAction(_ sender: Any?) {
        NSWorkspace.shared.open(BooPaths.documentationURL)
    }

    @objc func checkForUpdatesAction(_ sender: Any?) {
        SparkleUpdater.shared.checkForUpdates()
    }
}
