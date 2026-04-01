import Cocoa

extension MainWindowController {
    /// Process names that represent connections, not user-facing processes.
    /// Hidden from the status bar when a remote session indicator is already shown.
    static let connectionProcessNames: Set<String> = [
        "ssh", "mosh", "telnet", "docker", "kubectl", "podman"
    ]

    func refreshToolbar() {
        let wsItems = appState.workspaces.enumerated().map { (i, ws) in
            ToolbarView.WorkspaceItem(
                name: ws.displayName, isActive: i == appState.activeWorkspaceIndex, resolvedColor: ws.resolvedColor,
                isPinned: ws.isPinned, color: ws.color, hasCustomColor: ws.customColor != nil)
        }
        toolbar.update(workspaces: wsItems, tabs: [], sidebarVisible: sidebarVisible)
        // Sync side workspace bar if present
        if let sideBar = sideWorkspaceBar {
            let barItems = appState.workspaces.map { ws in
                WorkspaceBarView.Item(
                    name: ws.displayName, path: ws.folderPath, isPinned: ws.isPinned, color: ws.color,
                    hasCustomColor: ws.customColor != nil, resolvedColor: ws.resolvedColor)
            }
            sideBar.setItems(barItems, selectedIndex: appState.activeWorkspaceIndex)
        }
        refreshStatusBar()
    }

    func refreshStatusBar() {
        guard let ws = activeWorkspace else {
            statusBar.update(directory: "", paneCount: 0, tabCount: 0, runningProcess: "")
            return
        }
        let ctx = AppStore.shared.context
        let contextTab = findTab(ctx.terminalID)
        let fallbackTab = ctx == .empty ? ws.pane(for: ws.activePaneID)?.activeTab : nil
        let statusTab = contextTab ?? fallbackTab
        let activeRemoteSession = ctx.remoteSession
        var cwd = (activeRemoteSession != nil ? ctx.remoteCwd : nil) ?? ctx.cwd
        if cwd.isEmpty { cwd = statusTab?.workingDirectory ?? ws.folderPath }
        if activeRemoteSession != nil {
            cwd = Self.tildeContractRemotePath(cwd, session: activeRemoteSession, title: statusTab?.title)
        }
        let paneCount = ctx == .empty ? ws.panes.count : ctx.paneCount
        let tabCount = ctx == .empty ? (ws.pane(for: ws.activePaneID)?.tabs.count ?? 0) : ctx.tabCount
        var process = ctx.processName
        // Don't show process when it duplicates the path, looks like a directory,
        // is a local user@host prompt, or is a connection command redundant with
        // the remote session indicator
        if !process.isEmpty {
            let cwdLast = cwd.lastPathComponent
            let abbrevCwd = abbreviatePath(cwd)
            let looksLikePath =
                process.hasPrefix("~") || process.hasPrefix("/")
                || process.hasPrefix("\u{2026}") || process.hasPrefix("...")
                || process.contains("/")
            let isLocalPrompt = process.contains("@") && !TerminalBridge.titleLooksRemote(process)
            // Always hide connection commands (ssh, docker, etc.) — they're not user-facing processes
            let isConnectionCommand = Self.connectionProcessNames.contains(process.lowercased())
            // Hide when process matches the remote session name (e.g. "user@devbox")
            let isRemotePrompt = process.contains("@") && TerminalBridge.titleLooksRemote(process)
            if process == cwdLast || process == cwd || process == abbrevCwd
                || looksLikePath || process.hasSuffix(cwdLast) || isLocalPrompt
                || isConnectionCommand || isRemotePrompt
            {
                process = ""
            }
        }
        statusBar.isRemote = activeRemoteSession != nil
        statusBar.remoteSession = activeRemoteSession
        // Sync git changed count from plugin
        if let gitPlugin = pluginRegistry.plugin(for: "git-panel") as? GitPlugin {
            statusBar.gitChangedCount = gitPlugin.changedFileCount
        }
        statusBar.update(directory: cwd, paneCount: paneCount, tabCount: tabCount, runningProcess: process)
        refreshWindowTitle()
    }

    /// Contract an absolute remote path to tilde notation for display.
    /// Mirrors the logic in PaneView.tildeContractRemotePath so tab and status bar match.
    private static func tildeContractRemotePath(_ path: String, session: RemoteSessionType?, title: String?) -> String {
        var user: String?
        if let session, session.displayName.contains("@") {
            user = session.displayName.split(separator: "@").first.map(String.init)
        }
        if user == nil, let title = title?.trimmingCharacters(in: .whitespaces),
            let atIdx = title.firstIndex(of: "@")
        {
            user = String(title[..<atIdx])
        }
        let homes = ["/root", user.map { "/home/\($0)" }].compactMap { $0 }
        for home in homes {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
        }
        return path
    }

    func refreshWindowTitle() {
        guard let ws = activeWorkspace,
            let pane = ws.pane(for: ws.activePaneID),
            let tab = pane.activeTab
        else {
            window?.title = "Boo"
            return
        }
        // Use the terminal title if available (shows running process or shell prompt info),
        // otherwise fall back to the last path component of the working directory.
        // Filter out transient command titles (cd, git switch, etc.) that flash briefly.
        let title = tab.title.trimmingCharacters(in: .whitespaces)
        let isTransientCommand =
            title.hasPrefix("cd ") || title.hasPrefix("git switch ")
            || title.hasPrefix("git checkout ")
        if !title.isEmpty && !isTransientCommand {
            window?.title = title
        } else {
            let dir = tab.workingDirectory
            let name = dir.lastPathComponent
            window?.title = name.isEmpty ? "Boo" : name
        }
    }
}
