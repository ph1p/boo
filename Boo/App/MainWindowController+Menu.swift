import Cocoa

extension MainWindowController {
    func setupMenuItems() {
        WindowManager.shared.menuOwner = self
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = "Boo"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Boo", action: #selector(showAboutAction(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Check for Updates...", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettingsAction(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Secure Keyboard Entry", action: #selector(toggleSecureKeyboardEntryAction(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Boo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "n")
        let newWorkspace = NSMenuItem(
            title: "New Workspace", action: #selector(newWorkspaceAction(_:)), keyEquivalent: "N")
        newWorkspace.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newWorkspace)
        let openFolder = NSMenuItem(
            title: "Open Folder...", action: #selector(openFolderAction(_:)), keyEquivalent: "O")
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFolder)
        let recipes = NSMenuItem(title: "Recipes", action: nil, keyEquivalent: "")
        recipes.submenu = RecipesMenu.shared.makeMenu()
        fileMenu.addItem(recipes)
        fileMenu.addItem(
            withTitle: "New Agent Task...", action: #selector(newAgentTaskAction(_:)), keyEquivalent: "")
        fileMenu.addItem(
            withTitle: "Review Changes...", action: #selector(reviewChangesAction(_:)), keyEquivalent: "")
        fileMenu.addItem(
            withTitle: "Agent Timeline", action: #selector(agentTimelineAction(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "New Terminal Tab", action: #selector(newTabAction(_:)), keyEquivalent: "t")
        let browserTab = NSMenuItem(
            title: "New Browser Tab", action: #selector(newBrowserTabAction(_:)), keyEquivalent: "T")
        browserTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(browserTab)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveAction(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(saveAsAction(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(smartCloseAction(_:)), keyEquivalent: "w")
        let reopenClosedTab = NSMenuItem(
            title: "Undo Close", action: #selector(reopenTabAction(_:)), keyEquivalent: "z")
        reopenClosedTab.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(reopenClosedTab)
        fileMenu.addItem(.separator())
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePaneAction(_:)), keyEquivalent: "W")
        closePaneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closePaneItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.title = "View"
        let viewMenu = NSMenu(title: "View")
        let palette = NSMenuItem(
            title: "Command Palette…", action: #selector(showCommandPaletteAction(_:)), keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(palette)
        viewMenu.addItem(.separator())
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
        viewMenu.addItem(
            withTitle: "Reload Shaders and Ghostty Config", action: #selector(reloadShadersAction(_:)),
            keyEquivalent: "")
        // Browser items have no target: they resolve to the focused
        // BrowserContentView through the responder chain and stay disabled
        // otherwise. ⌘[ / ⌘] walk the focus history, so Back/Forward stay unbound.
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Open Location…", action: #selector(BrowserContentView.browserOpenLocationAction(_:)),
            keyEquivalent: "l")
        viewMenu.addItem(
            withTitle: "Reload Page", action: #selector(BrowserContentView.browserReloadAction(_:)),
            keyEquivalent: "r")
        viewMenu.addItem(
            withTitle: "Back", action: #selector(BrowserContentView.browserGoBackAction(_:)), keyEquivalent: "")
        viewMenu.addItem(
            withTitle: "Forward", action: #selector(BrowserContentView.browserGoForwardAction(_:)), keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(findAction(_:)), keyEquivalent: "f")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let termMenuItem = NSMenuItem()
        termMenuItem.title = "Terminal"
        let termMenu = NSMenu(title: "Terminal")
        termMenu.addItem(withTitle: "Clear Screen", action: #selector(clearScreenAction(_:)), keyEquivalent: "k")
        termMenu.addItem(
            withTitle: "Clear Scrollback", action: #selector(clearScrollbackAction(_:)), keyEquivalent: "K")
        (termMenu.items.last)?.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())
        termMenu.addItem(
            withTitle: "Previous Prompt", action: #selector(jumpToPreviousPromptAction(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        termMenu.addItem(
            withTitle: "Next Prompt", action: #selector(jumpToNextPromptAction(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        let copyOutput = NSMenuItem(
            title: "Copy Last Output", action: #selector(copyLastOutputAction(_:)), keyEquivalent: "c")
        copyOutput.keyEquivalentModifierMask = [.command, .option]
        termMenu.addItem(copyOutput)
        let quickSelect = NSMenuItem(
            title: "Quick Select", action: #selector(quickSelectAction(_:)), keyEquivalent: " ")
        quickSelect.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(quickSelect)
        let copyMode = NSMenuItem(title: "Copy Mode", action: #selector(copyModeAction(_:)), keyEquivalent: "c")
        copyMode.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(copyMode)
        termMenu.addItem(.separator())
        termMenu.addItem(
            withTitle: "Record Session", action: #selector(toggleRecordingAction(_:)), keyEquivalent: "")
        let marker = NSMenuItem(
            title: "Add Recording Marker", action: #selector(addRecordingMarkerAction(_:)), keyEquivalent: "M")
        marker.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(marker)
        termMenu.addItem(
            withTitle: "Record All Panes", action: #selector(recordAllPanesAction(_:)), keyEquivalent: "")
        termMenu.addItem(
            withTitle: "Stop All Recordings", action: #selector(stopAllRecordingsAction(_:)), keyEquivalent: "")
        termMenu.addItem(
            withTitle: "Open Recording…", action: #selector(openRecordingAction(_:)), keyEquivalent: "")
        termMenu.addItem(
            withTitle: "Show Recordings Folder", action: #selector(revealRecordingsFolderAction(_:)),
            keyEquivalent: "")
        termMenu.addItem(.separator())
        termMenu.addItem(withTitle: "Split Right", action: #selector(splitVerticalAction(_:)), keyEquivalent: "d")
        let splitH = NSMenuItem(title: "Split Down", action: #selector(splitHorizontalAction(_:)), keyEquivalent: "D")
        splitH.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(splitH)
        termMenu.addItem(.separator())

        // ⌘[ / ⌘] belong to Focus Back / Forward; ⌥⌘⇥ would open the app switcher.
        let focusNext = NSMenuItem(
            title: "Focus Next Pane", action: #selector(focusNextPaneAction(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command, .option]
        termMenu.addItem(focusNext)
        let focusPrev = NSMenuItem(
            title: "Focus Previous Pane", action: #selector(focusPrevPaneAction(_:)), keyEquivalent: "[")
        focusPrev.keyEquivalentModifierMask = [.command, .option]
        termMenu.addItem(focusPrev)
        let pickPane = NSMenuItem(title: "Pick Pane…", action: #selector(pickPaneAction(_:)), keyEquivalent: "p")
        pickPane.keyEquivalentModifierMask = [.command, .control]
        pickPane.toolTip = "Label every pane: type a label to focus it, or press Tab first to swap it with this one"
        termMenu.addItem(pickPane)
        let paneNumbers = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        let paneNumberMenu = NSMenu(title: "Focus Pane")
        for i in 1...9 {
            let item = NSMenuItem(
                title: "\(i)", action: #selector(focusPaneNumberAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = i - 1
            paneNumberMenu.addItem(item)
        }
        paneNumbers.submenu = paneNumberMenu
        termMenu.addItem(paneNumbers)
        // Arrow bindings match Ghostty's defaults: ⌥⌘ select, ⌃⌘ resize, ⌃⇧⌘ move.
        termMenu.addItem(
            paneDirectionMenu(
                title: "Select Pane", modifiers: [.command, .option],
                actions: [
                    #selector(focusPaneLeftAction(_:)), #selector(focusPaneRightAction(_:)),
                    #selector(focusPaneUpAction(_:)), #selector(focusPaneDownAction(_:))
                ]))
        termMenu.addItem(
            paneDirectionMenu(
                title: "Resize Pane", modifiers: [.command, .control],
                actions: [
                    #selector(resizePaneLeftAction(_:)), #selector(resizePaneRightAction(_:)),
                    #selector(resizePaneUpAction(_:)), #selector(resizePaneDownAction(_:))
                ]))
        termMenu.addItem(
            paneDirectionMenu(
                title: "Move Pane", modifiers: [.command, .control, .shift],
                actions: [
                    #selector(swapPaneLeftAction(_:)), #selector(swapPaneRightAction(_:)),
                    #selector(swapPaneUpAction(_:)), #selector(swapPaneDownAction(_:))
                ]))

        let zoom = NSMenuItem(
            title: "Zoom Pane", action: #selector(toggleZoomPaneAction(_:)), keyEquivalent: "\r")
        zoom.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(zoom)
        let handoff = NSMenuItem(
            title: "Send to Agent", action: #selector(sendContextToAgentAction(_:)), keyEquivalent: "\r")
        handoff.keyEquivalentModifierMask = [.command, .option]
        handoff.toolTip = "Paste the selection, or the last command's output, into the nearest coding agent's prompt"
        termMenu.addItem(handoff)
        let appendNote = NSMenuItem(
            title: "Append Selection to Note", action: #selector(appendSelectionToNoteAction(_:)), keyEquivalent: "")
        appendNote.toolTip = "Append the selection, or the last command's output, to this workspace's note"
        termMenu.addItem(appendNote)
        let broadcastItem = NSMenuItem(title: "Broadcast Input to", action: nil, keyEquivalent: "")
        let broadcastMenu = NSMenu(title: "Broadcast Input to")
        broadcastMenu.addItem(
            withTitle: "All Panes in Workspace", action: #selector(broadcastToAllPanesAction(_:)), keyEquivalent: "")
        broadcastMenu.addItem(
            withTitle: "Selected Panes…", action: #selector(broadcastToSelectedPanesAction(_:)), keyEquivalent: "")
        broadcastMenu.addItem(.separator())
        broadcastMenu.addItem(
            withTitle: "Stop Broadcasting", action: #selector(stopBroadcastAction(_:)), keyEquivalent: "")
        broadcastItem.submenu = broadcastMenu
        termMenu.addItem(broadcastItem)
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
        termMenu.addItem(.separator())

        termMenu.addItem(
            withTitle: "Start Remote Control Server",
            action: #selector(toggleRemoteControlAction(_:)), keyEquivalent: "")
        termMenu.addItem(
            withTitle: "Copy Remote Control URL",
            action: #selector(copyRemoteControlURLAction(_:)), keyEquivalent: "")

        termMenuItem.submenu = termMenu
        mainMenu.addItem(termMenuItem)

        // Bookmarks menu
        let bmMenuItem = NSMenuItem()
        bmMenuItem.title = "Bookmarks"
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

        mainMenu.addItem(makeAgentsMenuItem())

        // Plugins menu (rebuilt dynamically as plugins load/unload)
        let pluginsMenuItem = NSMenuItem()
        pluginsMenuItem.title = "Plugins"
        let pluginsMenu = NSMenu(title: "Plugins")
        pluginsMenu.addItem(
            withTitle: "No Plugin Commands", action: nil, keyEquivalent: "")
        pluginsMenuItem.submenu = pluginsMenu
        mainMenu.addItem(pluginsMenuItem)

        // Window menu — AppKit appends the open-window list to `windowsMenu`.
        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Move Workspace to New Window", action: #selector(moveWorkspaceToNewWindowAction(_:)),
            keyEquivalent: "")
        windowMenu.addItem(
            withTitle: "Merge All Windows", action: #selector(mergeAllWindowsAction(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // ⌥⌘O: ⇧⌘O is Open Folder.
        let orchestrator = NSMenuItem(
            title: "Toggle Orchestrator", action: #selector(toggleOrchestratorAction(_:)), keyEquivalent: "o")
        orchestrator.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(orchestrator)
        // Targeted: no window implements it, and the panel may not exist yet.
        let quickTerminal = NSMenuItem(
            title: "Toggle Quick Terminal",
            action: #selector(QuickTerminalController.toggleQuickTerminalAction(_:)), keyEquivalent: "")
        quickTerminal.target = QuickTerminalController.shared
        QuickTerminalController.shared.configure(quickTerminal)
        windowMenu.addItem(quickTerminal)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        helpMenuItem.title = "Help"
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Welcome to Boo", action: #selector(showWelcomeAction(_:)), keyEquivalent: "")
        helpMenu.addItem(
            withTitle: "Boo Documentation", action: #selector(openDocumentationAction(_:)), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApplication.shared.helpMenu = helpMenu

        // ⌘1-8 pick a workspace, ⌘9 the last one (as browsers do with tabs).
        viewMenu.addItem(.separator())
        let goToWorkspace = NSMenuItem(
            title: "Go to Workspace…", action: #selector(goToWorkspaceAction(_:)), keyEquivalent: "p")
        goToWorkspace.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(goToWorkspace)
        for i in 1...8 {
            let item = NSMenuItem(
                title: "Workspace \(i)", action: #selector(switchToWorkspaceAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1
            viewMenu.addItem(item)
        }
        let lastWorkspace = NSMenuItem(
            title: "Last Workspace", action: #selector(lastWorkspaceAction(_:)), keyEquivalent: "9")
        lastWorkspace.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(lastWorkspace)
        // ⌃⌘[ / ⌃⌘] land on ö / ä on a German layout; ⌃⌥⇥ is the same on every layout.
        addNavigationItem(
            to: viewMenu, title: "Next Workspace", action: #selector(nextWorkspaceAction(_:)),
            key: "]", modifiers: [.command, .control], twinKey: "\t", twinModifiers: [.control, .option])
        addNavigationItem(
            to: viewMenu, title: "Previous Workspace", action: #selector(previousWorkspaceAction(_:)),
            key: "[", modifiers: [.command, .control], twinKey: ShortcutOverrides.Shortcut.backTab,
            twinModifiers: [.control, .option, .shift])
        addNavigationItem(
            to: viewMenu, title: "Move Workspace Up", action: #selector(moveWorkspaceUpAction(_:)),
            key: "[", modifiers: [.command, .control, .option])
        addNavigationItem(
            to: viewMenu, title: "Move Workspace Down", action: #selector(moveWorkspaceDownAction(_:)),
            key: "]", modifiers: [.command, .control, .option])

        viewMenu.addItem(.separator())
        // ⇧ turns [ ] into { }, and AppKit matches the shifted character.
        addNavigationItem(
            to: viewMenu, title: "Next Tab", action: #selector(nextTabAction(_:)),
            key: "}", modifiers: [.command, .shift], twinKey: "\t", twinModifiers: [.control])
        addNavigationItem(
            to: viewMenu, title: "Previous Tab", action: #selector(previousTabAction(_:)),
            key: "{", modifiers: [.command, .shift], twinKey: ShortcutOverrides.Shortcut.backTab,
            twinModifiers: [.control, .shift])
        addNavigationItem(
            to: viewMenu, title: "Focus Back", action: #selector(focusBackAction(_:)),
            key: "[", modifiers: [.command])
        addNavigationItem(
            to: viewMenu, title: "Focus Forward", action: #selector(focusForwardAction(_:)),
            key: "]", modifiers: [.command])

        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)", action: #selector(switchToTabAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = i - 1
            viewMenu.addItem(item)

            // Same jump on ⇧⌘n. An alternate item so the menu lists each tab
            // once, revealing this binding while ⇧ is held.
            let shifted = NSMenuItem(
                title: "Tab \(i)", action: #selector(switchToTabAction(_:)), keyEquivalent: "\(i)")
            shifted.keyEquivalentModifierMask = [.command, .shift]
            shifted.tag = i - 1
            shifted.isAlternate = true
            viewMenu.addItem(shifted)
        }

        NSApplication.shared.mainMenu = mainMenu
        ShortcutOverrides.apply(to: mainMenu)
    }

    /// An item, plus an optional hidden twin with a second shortcut. The twin
    /// is an alternate, so the menu and palette list the command once.
    private func addNavigationItem(
        to menu: NSMenu, title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags,
        twinKey: String? = nil, twinModifiers: NSEvent.ModifierFlags = []
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        guard let twinKey else { return }
        let twin = NSMenuItem(title: title, action: action, keyEquivalent: twinKey)
        twin.keyEquivalentModifierMask = twinModifiers
        twin.isAlternate = true
        twin.isHidden = true
        menu.addItem(twin)
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
        sendRawToActivePane(ShellCommand.cd(shellEscape(bookmarks[idx].path)))
    }

    // MARK: - Plugins Menu

    /// Rebuild the Plugins top-level menu from current plugin contributions.
    /// The main menu and its top-level item titled `title`; nil unless this
    /// window owns the shared menu bar (background windows must not retarget it).
    func ownedTopMenuItem(titled title: String) -> (mainMenu: NSMenu, item: NSMenuItem)? {
        guard WindowManager.shared.ownsMenu(self), let mainMenu = NSApplication.shared.mainMenu,
            let item = mainMenu.items.first(where: { $0.submenu?.title == title })
        else { return nil }
        return (mainMenu, item)
    }

    func rebuildPluginsMenu() {
        guard let (mainMenu, pluginsMenuItem) = ownedTopMenuItem(titled: "Plugins"),
            let pluginsMenu = pluginsMenuItem.submenu
        else { return }

        pluginsMenu.removeAllItems()
        defer { ShortcutOverrides.apply(to: mainMenu) }

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
                                debugLog(
                                    "[Plugins] Shortcut conflict for '\(shortcut)' in \(contribution.pluginName), skipping"
                                )
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
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { collect(submenu) }
                guard !item.keyEquivalent.isEmpty else { continue }
                shortcuts.insert("\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)")
            }
        }
        for menuItem in mainMenu.items {
            guard let submenu = menuItem.submenu, submenu.title != "Plugins" else { continue }
            collect(submenu)
        }
        return shortcuts
    }

    /// Submenu with one item per direction (left, right, up, down) bound to
    /// the arrow keys with `modifiers`.
    private func paneDirectionMenu(
        title: String, modifiers: NSEvent.ModifierFlags, actions: [Selector]
    ) -> NSMenuItem {
        let keys = [NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey]
        let names = ["Left", "Right", "Up", "Down"]
        let menu = NSMenu(title: title)
        for i in 0..<4 {
            let item = NSMenuItem(
                title: names[i], action: actions[i], keyEquivalent: String(UnicodeScalar(keys[i])!))
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }
}
