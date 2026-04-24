import CGhostty
import Cocoa

extension MainWindowController {
    var activeGhosttyView: GhosttyView? {
        guard let workspace = activeWorkspace else { return nil }
        return ghosttyView(for: workspace.activePaneID)
    }

    func ghosttyView(for paneID: UUID) -> GhosttyView? {
        guard let pv = paneViews[paneID] else { return nil }
        // currentTerminalView may be a TerminalScrollView wrapping the GhosttyView
        if let gv = pv.currentTerminalView as? GhosttyView { return gv }
        if let wrapper = pv.currentTerminalView as? TerminalScrollView { return wrapper.ghosttyView }
        return nil
    }

    @objc func findAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        let wasVisible = pv.isFindBarVisible
        pv.showFindBar()
        if !wasVisible { activeGhosttyView?.startSearch() }
    }

    @objc func clearScreenAction(_ sender: Any?) {
        // Simulate Ctrl+L key press — the standard terminal clear screen
        activeGhosttyView?.sendKey(keyCode: 0x25, mods: GHOSTTY_MODS_CTRL, text: "l")
    }

    @objc func clearScrollbackAction(_ sender: Any?) {
        // Clear scrollback + screen via shell command
        sendRawToActivePane("printf '\\033[3J\\033[2J\\033[H'\r")
    }

    @objc func saveAction(_ sender: Any?) {
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID),
            let pv = paneViews[pane.id]
        else { return }
        pv.activeContentView?.save { success in
            if !success {
                debugLog("[MainWindow] Save failed")
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        activeGhosttyView?.copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        activeGhosttyView?.paste(sender)
    }

    @objc func focusNextPaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let ids = workspace.splitTree.leafIDs
        guard ids.count > 1 else { return }
        if let idx = ids.firstIndex(of: workspace.activePaneID) {
            let next = ids[(idx + 1) % ids.count]
            workspace.activePaneID = next
            paneViews[next]?.focusActiveView()
            runPluginCycle(reason: .focusChanged)
        }
    }

    @objc func focusPrevPaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let ids = workspace.splitTree.leafIDs
        guard ids.count > 1 else { return }
        if let idx = ids.firstIndex(of: workspace.activePaneID) {
            let prev = ids[(idx - 1 + ids.count) % ids.count]
            workspace.activePaneID = prev
            paneViews[prev]?.focusActiveView()
            runPluginCycle(reason: .focusChanged)
        }
    }

    @objc func increaseFontSizeAction(_ sender: Any?) {
        let current = AppSettings.shared.fontSize
        if current < 32 { AppSettings.shared.fontSize = current + 1 }
    }

    @objc func decreaseFontSizeAction(_ sender: Any?) {
        let current = AppSettings.shared.fontSize
        if current > 8 { AppSettings.shared.fontSize = current - 1 }
    }

    @objc func resetFontSizeAction(_ sender: Any?) {
        AppSettings.shared.fontSize = 14
    }

    @objc func toggleFullScreenAction(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc func equalizeSplitsAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        workspace.equalizeSplits()
        splitContainer.update(tree: workspace.splitTree)
    }

    func pastePathToActivePane(_ path: String) {
        // Paste uses ghostty_surface_text (bracketed paste) — appropriate for
        // inserting text without executing
        guard let gv = activeGhosttyView, let surface = gv.surface else { return }
        let escaped = shellEscape(path)
        escaped.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(strlen(cstr)))
        }
    }

    /// Send text to the active terminal as keyboard input (not paste).
    func sendRawToActivePane(_ text: String) {
        activeGhosttyView?.sendRaw(text)
    }

    func openDirectoryInNewTab(_ path: String) {
        guard let workspace = activeWorkspace,
            let pv = paneViews[workspace.activePaneID]
        else { return }
        pv.addNewTab(workingDirectory: path)
        refreshStatusBar()
    }

    /// Handle opening a tab via plugin API with type-safe payload.
    func handleOpenTab(_ payload: TabPayload) {
        guard let workspace = activeWorkspace,
            let pv = paneViews[workspace.activePaneID]
        else { return }

        switch payload {
        case .terminal(let workingDirectory):
            pv.addNewTab(contentType: .terminal, workingDirectory: workingDirectory)

        case .terminalWithCommand(let workingDirectory, let command):
            pv.addNewTab(contentType: .terminal, workingDirectory: workingDirectory)
            // Send command after tab is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.sendRawToActivePane(command + "\n")
            }

        case .browser(let url):
            pv.addNewTab(contentType: .browser, url: url)

        case .file(let path):
            // Check if file has a known content type (image, markdown, PDF, etc.)
            if let type = ContentType.forFile(path) {
                // Markdown respects user preference
                if type == .markdownPreview {
                    switch AppSettings.shared.markdownOpenMode {
                    case .preview:
                        openFileInTab(path: path, type: .markdownPreview)
                    case .terminalEditor:
                        openFileInTerminalEditor(path)
                    case .builtInEditor, .multiContent:
                        openFileInTab(path: path, type: .editor)
                    case .external:
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                } else if type == .browser {
                    // PDF (and any future file-URL-browser types): open directly as browser tab
                    pv.addNewTab(contentType: .browser, url: URL(fileURLWithPath: path))
                } else {
                    openFileInTab(path: path, type: type)
                }
            } else if ContentType.isEditorFilePattern(filename: ((path as NSString).lastPathComponent).lowercased()) {
                // File matches user-configured editor patterns — open in built-in editor tab
                openFileInTab(path: path, type: .editor)
            } else {
                // Unknown type: open in system default app
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }

        case .customView(let title, let icon, let view):
            pv.addPluginViewTab(view: view, title: title, icon: icon)
        }
        refreshStatusBar()
    }

    /// Open a file in a new tab with the specified content type.
    private func openFileInTab(path: String, type: ContentType) {
        guard let workspace = activeWorkspace,
            let pv = paneViews[workspace.activePaneID]
        else { return }

        let parentDir = (path as NSString).deletingLastPathComponent
        pv.addNewTab(contentType: type, workingDirectory: parentDir)

        // For file-based content views, we need to load the file after tab creation
        if let contentView = pv.activeContentView {
            switch type {
            case .markdownPreview:
                let state = ContentState.markdownPreview(
                    MarkdownPreviewContentState(
                        title: (path as NSString).lastPathComponent,
                        filePath: path,
                        scrollPosition: 0
                    )
                )
                contentView.restoreState(state)
            case .imageViewer:
                let state = ContentState.imageViewer(
                    ImageViewerContentState(
                        title: (path as NSString).lastPathComponent,
                        filePath: path,
                        zoom: 1.0
                    )
                )
                contentView.restoreState(state)
            case .editor:
                let state = ContentState.editor(
                    EditorContentState(
                        title: (path as NSString).lastPathComponent,
                        filePath: path,
                        isDirty: false
                    )
                )
                contentView.restoreState(state)
            default:
                break
            }
        }
    }

    /// Open a file in the terminal editor (respects user's editor preference).
    private func openFileInTerminalEditor(_ path: String) {
        let parentDir = (path as NSString).deletingLastPathComponent
        openDirectoryInNewTab(parentDir)

        let configured = AppSettings.shared.fileEditorCommand.trimmingCharacters(in: .whitespaces)
        let editorCmd =
            configured.isEmpty
            ? (ProcessInfo.processInfo.environment["EDITOR"] ?? "vi")
            : configured

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendRawToActivePane("\(editorCmd) \(shellEscape(path))\r")
        }
    }

    /// Open or focus a custom tab registered via registerMultiContentTab.
    /// If a tab with the same typeID + context.key already exists in the active workspace,
    /// it is focused rather than creating a duplicate.
    func handleOpenMultiContentTab(typeID: String, context: PluginTabContext) {
        guard let factory = multiContentTabFactories[typeID] else { return }
        guard let workspace = activeWorkspace else { return }

        // Search all panes in the active workspace for an existing tab with this typeID+key
        let dedupeKey = "\(typeID):\(context.key)"
        for (paneID, pane) in workspace.panes {
            if let pv = paneViews[paneID],
                let idx = pane.tabs.firstIndex(where: { registeredTabKey(for: $0.id) == dedupeKey })
            {
                // Focus existing tab
                workspace.activePaneID = paneID
                pv.forceActivateTab(idx)
                return
            }
        }

        // Not found — create a new one
        guard let pv = paneViews[workspace.activePaneID] else { return }
        let view = factory(context)
        if let tabID = pv.addPluginViewTab(view: view, title: context.title, icon: context.icon) {
            registeredTabKeys[tabID] = dedupeKey
        }
        refreshStatusBar()
    }

    /// Returns the registered typeID:key string for a tab, if it was opened via registerMultiContentTab.
    private func registeredTabKey(for tabID: UUID) -> String? {
        registeredTabKeys[tabID]
    }

    /// Open a file content tab (editor, image viewer, etc.) in a new split pane.
    func openFileInNewPane(_ path: String) {
        guard let workspace = activeWorkspace else { return }
        window?.makeFirstResponder(nil)

        let newID = workspace.splitPane(workspace.activePaneID, direction: .horizontal)
        workspace.activePaneID = newID
        splitContainer.update(tree: workspace.splitTree)
        saveSession()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pv = self.paneViews[newID] {
                pv.startActiveSession()
                self.window?.makeFirstResponder(pv.ghosttyView)
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            // Now open the file in the new pane (which is now active)
            self.handleOpenTab(.file(path: path))
        }
    }

    func openDirectoryInNewPane(_ path: String) {
        guard let workspace = activeWorkspace else { return }
        window?.makeFirstResponder(nil)

        let newID = workspace.splitPane(workspace.activePaneID, direction: .horizontal)
        // Override the new pane's tab to use the selected directory
        if let pane = workspace.pane(for: newID) {
            pane.stopAll()
            // Re-init with the chosen directory
            _ = pane.addTab(workingDirectory: path)
        }
        workspace.activePaneID = newID
        splitContainer.update(tree: workspace.splitTree)
        saveSession()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pv = self.paneViews[newID] {
                pv.startActiveSession()
                self.window?.makeFirstResponder(pv.ghosttyView)
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            self.refreshStatusBar()
        }
    }

    /// Flush a pending image send for `paneID` if a shell PID is available.
    /// Called from both `onShellPIDUpdated` (new PID registered) and `didFocus`
    /// (pane becomes active — shell must be running if user can interact with it).
    /// Flush a pending image send keyed by `tabID`.
    /// `shellPID` is the PID to send to; if nil, look up the current pane PID (for didFocus path).
    func flushPendingImageSend(for tabID: UUID, shellPID: pid_t? = nil, paneID: UUID? = nil) {
        guard let pending = pendingImageSends[tabID] else { return }
        let pid: pid_t?
        if let shellPID {
            pid = shellPID
        } else if let paneID {
            pid = bridge.monitor.shellPID(for: paneID)
        } else {
            return
        }
        guard let pid, pid != pending.failedPID else { return }
        pendingImageSends.removeValue(forKey: tabID)
        let path = pending.path
        let size = pending.size
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = KittyImageProtocol.sendImage(imagePath: path, to: pid, terminalSize: size)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ok {
                } else {
                    self.pendingImageSends[tabID] = (path, size, pid)
                    // Trigger a shell PID refresh — zsh may have re-exec'd to a new PID.
                    if let paneID {
                        self.ghosttyView(for: paneID)?.refreshShellPIDIfNeeded(currentPID: pid)
                    }
                }
            }
        }
    }

    /// Refresh all Ghostty surfaces — call after view hierarchy changes (splits, close, resize).
    func refreshAllSurfaces() {
        guard let ws = activeWorkspace else { return }
        let activeID = ws.activePaneID
        for (paneID, pv) in paneViews {
            pv.layoutTerminalView()
            let isActive = paneID == activeID
            pv.isFocused = isActive
            guard let gv = pv.ghosttyView, let surface = gv.surface else { continue }
            gv.setFocused(isActive)
            let scaledSize = gv.convertToBacking(gv.bounds.size)
            let w = UInt32(scaledSize.width)
            let h = UInt32(scaledSize.height)
            if w > 0 && h > 0 {
                ghostty_surface_set_size(surface, w, h)
            }
            // Only force-refresh the active pane; inactive panes repaint via normal display cycle
            if isActive {
                ghostty_surface_refresh(surface)
            }
        }
    }
}
