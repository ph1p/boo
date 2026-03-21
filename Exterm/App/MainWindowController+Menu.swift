import Cocoa

extension MainWindowController {
    func setupMenuItems() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Exterm", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettingsAction(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Exterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        // Cmd+1 through Cmd+9 for workspace switching
        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Workspace \(i)", action: #selector(switchToWorkspaceAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1
            viewMenu.addItem(item)
        }

        NSApplication.shared.mainMenu = mainMenu
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
}
