import Cocoa

extension MainWindowController {
    func setupMenuItems() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Boo", action: #selector(showAboutAction(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Check for Updates...", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettingsAction(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Boo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Workspace", action: #selector(newWorkspaceAction(_:)), keyEquivalent: "n")
        let openFolder = NSMenuItem(
            title: "Open Folder...", action: #selector(openFolderAction(_:)), keyEquivalent: "O")
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFolder)
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTabAction(_:)), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(smartCloseAction(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenTabAction(_:)), keyEquivalent: "z")
        fileMenu.addItem(.separator())
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePaneAction(_:)), keyEquivalent: "W")
        closePaneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closePaneItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebarAction(_:)), keyEquivalent: "b")
        let fullscreen = NSMenuItem(
            title: "Toggle Full Screen", action: #selector(toggleFullScreenAction(_:)), keyEquivalent: "\r")
        fullscreen.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(fullscreen)
        let fullscreenAlt = NSMenuItem(
            title: "Toggle Full Screen", action: #selector(toggleFullScreenAction(_:)), keyEquivalent: "f")
        fullscreenAlt.keyEquivalentModifierMask = [.command, .control]
        fullscreenAlt.isAlternate = true
        viewMenu.addItem(fullscreenAlt)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyAction(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(GhosttyView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let termMenuItem = NSMenuItem()
        let termMenu = NSMenu(title: "Terminal")
        termMenu.addItem(withTitle: "Clear Screen", action: #selector(clearScreenAction(_:)), keyEquivalent: "k")
        termMenu.addItem(
            withTitle: "Clear Scrollback", action: #selector(clearScrollbackAction(_:)), keyEquivalent: "K")
        (termMenu.items.last)?.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())
        termMenu.addItem(withTitle: "Split Right", action: #selector(splitVerticalAction(_:)), keyEquivalent: "d")
        let splitH = NSMenuItem(title: "Split Down", action: #selector(splitHorizontalAction(_:)), keyEquivalent: "D")
        splitH.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(splitH)
        termMenu.addItem(.separator())

        let focusNext = NSMenuItem(
            title: "Focus Next Pane", action: #selector(focusNextPaneAction(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command]
        termMenu.addItem(focusNext)
        let focusPrev = NSMenuItem(
            title: "Focus Previous Pane", action: #selector(focusPrevPaneAction(_:)), keyEquivalent: "[")
        focusPrev.keyEquivalentModifierMask = [.command]
        termMenu.addItem(focusPrev)

        let equalize = NSMenuItem(
            title: "Equalize Splits", action: #selector(equalizeSplitsAction(_:)), keyEquivalent: "=")
        equalize.keyEquivalentModifierMask = [.command, .control]
        termMenu.addItem(equalize)
        termMenu.addItem(.separator())

        let fontUp = NSMenuItem(
            title: "Increase Font Size", action: #selector(increaseFontSizeAction(_:)), keyEquivalent: "+")
        fontUp.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontUp)
        let fontDown = NSMenuItem(
            title: "Decrease Font Size", action: #selector(decreaseFontSizeAction(_:)), keyEquivalent: "-")
        fontDown.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontDown)
        let fontReset = NSMenuItem(
            title: "Reset Font Size", action: #selector(resetFontSizeAction(_:)), keyEquivalent: "0")
        fontReset.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontReset)

        termMenuItem.submenu = termMenu
        mainMenu.addItem(termMenuItem)

        // Bookmarks menu
        let bmMenuItem = NSMenuItem()
        let bmMenu = NSMenu(title: "Bookmarks")
        let addBm = NSMenuItem(
            title: "Bookmark Current Directory", action: #selector(bookmarkCurrentAction(_:)), keyEquivalent: "B")
        addBm.keyEquivalentModifierMask = [.command, .shift]
        bmMenu.addItem(addBm)
        bmMenu.addItem(.separator())
        // Ctrl+1 through Ctrl+9 for bookmark jumping
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Jump to Bookmark \(i)", action: #selector(jumpToBookmarkAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.control]
            item.tag = i - 1
            bmMenu.addItem(item)
        }
        bmMenuItem.submenu = bmMenu
        mainMenu.addItem(bmMenuItem)

        // Plugins menu (rebuilt dynamically as plugins load/unload)
        let pluginsMenuItem = NSMenuItem()
        let pluginsMenu = NSMenu(title: "Plugins")
        pluginsMenu.addItem(
            withTitle: "No Plugin Commands", action: nil, keyEquivalent: "")
        pluginsMenuItem.submenu = pluginsMenu
        mainMenu.addItem(pluginsMenuItem)

        // Cmd+1 through Cmd+9 for workspace switching
        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Workspace \(i)", action: #selector(switchToWorkspaceAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1
            viewMenu.addItem(item)
        }

        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)", action: #selector(switchToTabAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = i - 1
            viewMenu.addItem(item)
        }

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func switchToTabAction(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID),
            let pv = paneViews[ws.activePaneID],
            idx < pane.tabs.count
        else { return }
        pv.activateTab(idx)
    }

    @objc func switchToWorkspaceAction(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < appState.workspaces.count else { return }
        guard idx != appState.activeWorkspaceIndex else { return }
        activateWorkspace(idx)
    }

    @objc func bookmarkCurrentAction(_ sender: Any?) {
        guard let ws = activeWorkspace else { return }
        let cwd =
            ws.pane(for: ws.activePaneID)?.activeTab?.workingDirectory
            ?? ws.folderPath
        guard !cwd.isEmpty else { return }
        BookmarkService.shared.addCurrentDirectory(cwd)
        statusBar.needsDisplay = true
    }

    @objc func jumpToBookmarkAction(_ sender: NSMenuItem) {
        let idx = sender.tag
        let bookmarks = BookmarkService.shared.bookmarks
        guard idx >= 0, idx < bookmarks.count else { return }
        sendRawToActivePane("cd \(shellEscape(bookmarks[idx].path))\r")
    }

    // MARK: - Plugins Menu

    /// Rebuild the Plugins top-level menu from current plugin contributions.
    func rebuildPluginsMenu() {
        guard let mainMenu = NSApplication.shared.mainMenu,
            let pluginsMenuItem = mainMenu.items.first(where: { $0.submenu?.title == "Plugins" }),
            let pluginsMenu = pluginsMenuItem.submenu
        else { return }

        pluginsMenu.removeAllItems()

        guard let context = pluginRegistry.lastContext else {
            pluginsMenu.addItem(withTitle: "No Plugin Commands", action: nil, keyEquivalent: "")
            return
        }

        let contributions = pluginRegistry.collectMenuContributions(context: context)
        if contributions.isEmpty {
            pluginsMenu.addItem(withTitle: "No Plugin Commands", action: nil, keyEquivalent: "")
            return
        }

        // Collect all built-in shortcuts to detect conflicts
        let builtinShortcuts = collectBuiltinShortcuts()

        for (idx, contribution) in contributions.enumerated() {
            if idx > 0 { pluginsMenu.addItem(.separator()) }

            // Plugin name as section header
            let header = NSMenuItem(title: contribution.pluginName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            pluginsMenu.addItem(header)

            for entry in contribution.items {
                switch entry {
                case .separator:
                    pluginsMenu.addItem(.separator())
                case .item(let menuItem):
                    let nsItem = NSMenuItem(
                        title: menuItem.label,
                        action: #selector(pluginMenuAction(_:)),
                        keyEquivalent: "")
                    nsItem.target = self
                    nsItem.representedObject = [
                        "pluginID": contribution.pluginID,
                        "action": menuItem.actionName
                    ]

                    if let iconName = menuItem.icon,
                        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: menuItem.label)
                    {
                        nsItem.image = img
                    }

                    // Parse and apply keyboard shortcut
                    if let shortcut = menuItem.shortcut {
                        let (key, modifiers) = Self.parseShortcut(shortcut)
                        if !key.isEmpty {
                            let combo = "\(modifiers.rawValue):\(key)"
                            if builtinShortcuts.contains(combo) {
                                NSLog("[Plugins] Shortcut conflict for '\(shortcut)' in \(contribution.pluginName), skipping")
                            } else {
                                nsItem.keyEquivalent = key
                                nsItem.keyEquivalentModifierMask = modifiers
                            }
                        }
                    }

                    pluginsMenu.addItem(nsItem)
                }
            }
        }
    }

    @objc func pluginMenuAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
            let pluginID = info["pluginID"],
            let actionName = info["action"],
            let context = pluginRegistry.lastContext
        else { return }
        pluginRegistry.dispatchMenuAction(pluginID: pluginID, actionName: actionName, context: context)
    }

    /// Parse a shortcut string like "shift+cmd+t" into (keyEquivalent, modifierMask).
    static func parseShortcut(_ shortcut: String) -> (String, NSEvent.ModifierFlags) {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
        var modifiers: NSEvent.ModifierFlags = []
        var key = ""

        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            default: key = part
            }
        }
        return (key, modifiers)
    }

    /// Collect all built-in keyboard shortcuts as "modifiers:key" strings for conflict detection.
    private func collectBuiltinShortcuts() -> Set<String> {
        var shortcuts = Set<String>()
        guard let mainMenu = NSApplication.shared.mainMenu else { return shortcuts }
        for menuItem in mainMenu.items {
            guard let submenu = menuItem.submenu, submenu.title != "Plugins" else { continue }
            for item in submenu.items where !item.keyEquivalent.isEmpty {
                let combo = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                shortcuts.insert(combo)
            }
        }
        return shortcuts
    }
}
