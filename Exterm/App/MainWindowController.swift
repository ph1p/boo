import Cocoa
import SwiftUI

/// NSSplitView with themed divider color.
class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        AppSettings.shared.theme.chromeMuted.withAlphaComponent(0.2)
    }
}

class MainWindowController: NSWindowController, ToolbarViewDelegate, SplitContainerDelegate, PaneViewDelegate, NSSplitViewDelegate {
    private let appState = AppState()

    private let toolbar = ToolbarView(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)
    private var splitContainer: SplitContainerView!
    private var sidebarContainer: NSView!
    private var sidebarHostingView: NSHostingView<FileTreeView>?
    private var mainSplitView: NSSplitView!

    private var fileTreeRoot: FileTreeNode?
    private var remoteTreeRoot: RemoteFileTreeNode?
    private var fileWatcher: FileSystemWatcher?
    private var sidebarVisible = true
    private var isRemoteSidebar = false
    private var remoteRefreshTimer: Timer?

    private var paneViews: [UUID: PaneView] = [:]
    private var settingsObserver: Any?

    /// Undo stack for closed tabs and panes
    enum ClosedItem {
        case tab(paneID: UUID, workingDirectory: String, index: Int)
        case pane(siblingPaneID: UUID, workingDirectory: String, direction: SplitTree.SplitDirection)
    }
    private var undoStack: [ClosedItem] = []

    /// Keep closed sessions alive briefly so undo can restore them
    private var sessionCache: [(session: TerminalSession, expiry: Date)] = []
    private var sessionCacheTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Exterm"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("ExtermMainWindow")
        window.backgroundColor = AppSettings.shared.theme.chromeBg
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        super.init(window: window)

        setupUI()
        setupMenuItems()

        openWorkspace(path: FileManager.default.homeDirectoryForCurrentUser.path)

        // Cleanup expired cached sessions every 10 seconds
        sessionCacheTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.cleanSessionCache()
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            // Refresh chrome colors
            let theme = AppSettings.shared.theme
            self.window?.backgroundColor = theme.chromeBg
            self.sidebarContainer.layer?.backgroundColor = theme.sidebarBg.cgColor
            self.splitContainer.layer?.backgroundColor = theme.background.nsColor.cgColor
            self.mainSplitView.needsDisplay = true // Redraws themed divider
            self.toolbar.needsDisplay = true
            self.statusBar.needsDisplay = true
            for (_, pv) in self.paneViews {
                pv.layer?.backgroundColor = theme.background.nsColor.cgColor
                pv.needsDisplay = true
            }
            // Only refresh file tree if sidebar-relevant settings changed
            if self.sidebarVisible {
                self.fileTreeRoot?.refreshAll()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var activeWorkspace: Workspace? { appState.activeWorkspace }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.delegate = self
        contentView.addSubview(toolbar)

        mainSplitView = ThemedSplitView()
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.delegate = self
        contentView.addSubview(mainSplitView)

        splitContainer = SplitContainerView(frame: .zero)
        splitContainer.splitDelegate = self
        mainSplitView.addSubview(splitContainer)

        sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor
        mainSplitView.addSubview(sidebarContainer)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.onBranchSwitch = { [weak self] branch in
            self?.sendRawToActivePane("git switch \(branch)\n")
        }
        contentView.addSubview(statusBar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),

            mainSplitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pos = self.mainSplitView.bounds.width - 240
            if pos > 300 { self.mainSplitView.setPosition(pos, ofDividerAt: 0) }
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView { return 300 }
        return p
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView == mainSplitView { return splitView.bounds.width - 140 }
        return p
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt i: Int) -> Bool {
        if splitView == mainSplitView { return !sidebarVisible }
        return false
    }

    func splitView(_ splitView: NSSplitView, effectiveRect r: NSRect, forDrawnRect d: NSRect, ofDividerAt i: Int) -> NSRect {
        if splitView == mainSplitView && !sidebarVisible { return .zero }
        return r
    }

    private func setupMenuItems() {
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
        let openFolder = NSMenuItem(title: "Open Folder...", action: #selector(openFolderAction(_:)), keyEquivalent: "O")
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
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyAction(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let termMenuItem = NSMenuItem()
        let termMenu = NSMenu(title: "Terminal")
        termMenu.addItem(withTitle: "Clear Screen", action: #selector(clearScreenAction(_:)), keyEquivalent: "k")
        termMenu.addItem(withTitle: "Clear Scrollback", action: #selector(clearScrollbackAction(_:)), keyEquivalent: "K")
        (termMenu.items.last)?.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())
        termMenu.addItem(withTitle: "Split Right", action: #selector(splitVerticalAction(_:)), keyEquivalent: "d")
        let splitH = NSMenuItem(title: "Split Down", action: #selector(splitHorizontalAction(_:)), keyEquivalent: "D")
        splitH.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(splitH)
        termMenu.addItem(.separator())

        let focusNext = NSMenuItem(title: "Focus Next Pane", action: #selector(focusNextPaneAction(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command]
        termMenu.addItem(focusNext)
        let focusPrev = NSMenuItem(title: "Focus Previous Pane", action: #selector(focusPrevPaneAction(_:)), keyEquivalent: "[")
        focusPrev.keyEquivalentModifierMask = [.command]
        termMenu.addItem(focusPrev)
        termMenu.addItem(.separator())

        let fontUp = NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSizeAction(_:)), keyEquivalent: "+")
        fontUp.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontUp)
        let fontDown = NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSizeAction(_:)), keyEquivalent: "-")
        fontDown.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontDown)
        let fontReset = NSMenuItem(title: "Reset Font Size", action: #selector(resetFontSizeAction(_:)), keyEquivalent: "0")
        fontReset.keyEquivalentModifierMask = [.command]
        termMenu.addItem(fontReset)

        termMenuItem.submenu = termMenu
        mainMenu.addItem(termMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Toolbar

    private func refreshToolbar() {
        let wsItems = appState.workspaces.enumerated().map { (i, ws) in
            ToolbarView.WorkspaceItem(name: ws.displayName, isActive: i == appState.activeWorkspaceIndex, resolvedColor: ws.resolvedColor, isPinned: ws.isPinned)
        }
        toolbar.update(workspaces: wsItems, tabs: [], sidebarVisible: sidebarVisible)
        refreshStatusBar()
    }

    private func refreshStatusBar() {
        guard let ws = activeWorkspace else {
            statusBar.update(directory: "", paneCount: 0, tabCount: 0, runningProcess: "")
            return
        }
        let session = ws.pane(for: ws.activePaneID)?.activeSession
        let cwd = session?.currentDirectory ?? ws.currentDirectory
        let paneCount = ws.panes.count
        let tabCount = ws.pane(for: ws.activePaneID)?.tabs.count ?? 0
        let fg = session?.foregroundProcess ?? ""
        statusBar.update(directory: cwd, paneCount: paneCount, tabCount: tabCount, runningProcess: fg)
    }

    // MARK: - Workspace

    func openWorkspace(path: String) {
        let workspace = Workspace(folderPath: path)
        workspace.onDirectoryChanged = { [weak self] newPath in
            guard let self = self, self.activeWorkspace?.id == workspace.id else { return }
            self.updateSidebar(path: newPath)
        }
        appState.addWorkspace(workspace)
        activateWorkspace(appState.workspaces.count - 1)
    }

    private func activateWorkspace(_ index: Int) {
        appState.setActiveWorkspace(index)
        guard let workspace = activeWorkspace else { return }

        paneViews.removeAll()
        refreshToolbar()
        updateSidebar(path: workspace.currentDirectory)
        splitContainer.update(tree: workspace.splitTree)

        // Focus the active pane
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let ws = self.activeWorkspace else { return }
            if let pv = self.paneViews[ws.activePaneID] {
                pv.startActiveSession()
                self.window?.makeFirstResponder(pv.currentTerminalView)
            }
        }
    }

    // MARK: - Sidebar

    private func clearSidebar() {
        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor
        sidebarContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func updateSidebar(path: String) {
        isRemoteSidebar = false
        remoteRefreshTimer?.invalidate()
        remoteRefreshTimer = nil
        fileWatcher?.stop()

        let folderName = (path as NSString).lastPathComponent
        let root = FileTreeNode(name: folderName, path: path, isDirectory: true)
        root.loadChildren()
        root.isExpanded = true
        self.fileTreeRoot = root

        sidebarContainer.layer?.backgroundColor = AppSettings.shared.theme.sidebarBg.cgColor
        clearSidebar()

        let actions = FileTreeActions(
            onFileClicked: { [weak self] path in
                self?.pastePathToActivePane(path)
            },
            onOpenInTab: { [weak self] path in
                self?.openDirectoryInNewTab(path)
            },
            onOpenInPane: { [weak self] path in
                self?.openDirectoryInNewPane(path)
            },
            onCopyPath: { path in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            onRevealInFinder: { path in
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
            }
        )
        let sidebarView = FileTreeView(root: root, actions: actions)
        let hostingView = NSHostingView(rootView: sidebarView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])
        sidebarHostingView = hostingView

        fileWatcher = FileSystemWatcher(path: path) { [weak self] in
            self?.fileTreeRoot?.refreshAll()
        }
        fileWatcher?.start()
    }

    private var activeRemoteSession: RemoteSessionType?

    private func showRemoteConnecting(session: RemoteSessionType) {
        guard !isRemoteSidebar || activeRemoteSession != session else { return }
        isRemoteSidebar = true
        activeRemoteSession = session
        fileWatcher?.stop()
        remoteRefreshTimer?.invalidate()
        remoteRefreshTimer = nil

        clearSidebar()

        let connectingView = NSHostingView(rootView: RemoteConnectingView(session: session))
        connectingView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(connectingView)

        NSLayoutConstraint.activate([
            connectingView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            connectingView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            connectingView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            connectingView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])
    }

    private func showRemoteSidebar(session: RemoteSessionType, remotePath: String) {
        isRemoteSidebar = true
        activeRemoteSession = session
        fileWatcher?.stop()

        let displayName = (remotePath as NSString).lastPathComponent.isEmpty ? "/" : (remotePath as NSString).lastPathComponent
        let root = RemoteFileTreeNode(
            name: displayName,
            remotePath: remotePath,
            isDirectory: true,
            session: session
        )
        root.isExpanded = true
        root.loadChildren()
        self.remoteTreeRoot = root

        clearSidebar()

        let actions = FileTreeActions(
            onFileClicked: { [weak self] path in
                self?.pastePathToActivePane(path)
            },
            onCopyPath: { path in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            onRunCommand: { [weak self] cmd in
                self?.sendRawToActivePane(cmd)
            }
        )

        let sidebarView = RemoteFileTreeView(root: root, actions: actions, host: session.displayName)
        let hostingView = NSHostingView(rootView: sidebarView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Periodically refresh remote tree
        remoteRefreshTimer?.invalidate()
        remoteRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.remoteTreeRoot?.refreshAll()
        }
    }

    // MARK: - ToolbarViewDelegate

    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int) {
        guard index != appState.activeWorkspaceIndex else { return }
        activateWorkspace(index)
    }

    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }
        let ws = appState.workspaces[index]
        guard !ws.isPinned else { return }

        // If workspace has multiple panes or tabs, ask for confirmation
        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        if ws.panes.count > 1 || totalTabs > 1 {
            let alert = NSAlert()
            alert.messageText = "Close workspace \"\(ws.displayName)\"?"
            alert.informativeText = "This will close \(ws.panes.count) pane\(ws.panes.count == 1 ? "" : "s") and \(totalTabs) tab\(totalTabs == 1 ? "" : "s")."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Workspace")
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: window!) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.forceCloseWorkspace(at: index)
            }
        } else {
            forceCloseWorkspace(at: index)
        }
    }

    private func forceCloseWorkspace(at index: Int) {
        appState.removeWorkspace(at: index)
        if appState.workspaces.isEmpty {
            window?.close()
        } else {
            activateWorkspace(appState.activeWorkspaceIndex)
        }
    }

    func toolbar(_ toolbar: ToolbarView, didSelectTabAt index: Int) { }
    func toolbar(_ toolbar: ToolbarView, didCloseTabAt index: Int) { }
    func toolbarDidRequestNewTab(_ toolbar: ToolbarView) { newTabAction(nil) }
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView) { toggleSidebarAction(nil) }

    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customName = name
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].color = color
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].customColor = (color == .clear) ? nil : color
        refreshToolbar()
    }

    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int) {
        guard index >= 0, index < appState.workspaces.count else { return }
        appState.workspaces[index].isPinned.toggle()
        refreshToolbar()
    }

    // MARK: - SplitContainerDelegate

    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView {
        if let existing = paneViews[paneID] {
            return existing
        }

        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: paneID) else {
            return PaneView(paneID: paneID, pane: Pane(id: paneID))
        }

        let pv = PaneView(paneID: paneID, pane: pane)
        pv.paneDelegate = self
        paneViews[paneID] = pv
        return pv
    }

    // MARK: - PaneViewDelegate

    func paneView(_ paneView: PaneView, didFocus paneID: UUID) {
        guard let workspace = activeWorkspace else { return }
        workspace.activePaneID = paneID
        if let pane = workspace.pane(for: paneID),
           let session = pane.activeSession {
            workspace.handleDirectoryChange(session.currentDirectory)

            // Check SSH state for this pane
            if let remote = session.remoteSession, let cwd = session.remoteCwd {
                showRemoteSidebar(session: remote, remotePath: cwd)
            } else if isRemoteSidebar {
                updateSidebar(path: session.currentDirectory)
            }
        }
        refreshStatusBar()
    }

    func paneView(_ paneView: PaneView, sessionForPane paneID: UUID, tabIndex: Int, workingDirectory: String) -> TerminalSession {
        guard let tv = paneView.currentTerminalView else {
            fatalError("PaneView has no terminal view")
        }
        let session = TerminalSession(terminalView: tv, workingDirectory: workingDirectory)
        return session
    }

    func paneView(_ paneView: PaneView, didChangeDirectory path: String, paneID: UUID) {
        guard let workspace = activeWorkspace, workspace.activePaneID == paneID else { return }
        workspace.handleDirectoryChange(path)
        refreshStatusBar()
    }

    func paneView(_ paneView: PaneView, foregroundProcessChanged name: String, paneID: UUID) {
        refreshStatusBar()
    }

    func paneView(_ paneView: PaneView, remoteStateChanged session: RemoteSessionType?, remoteCwd: String?, paneID: UUID) {
        guard let workspace = activeWorkspace, workspace.activePaneID == paneID else { return }

        if let session = session, let cwd = remoteCwd {
            // Connected — show file tree
            showRemoteSidebar(session: session, remotePath: cwd)
        } else if let session = session {
            // Detected but not yet connected — show connecting state
            showRemoteConnecting(session: session)
        } else if isRemoteSidebar {
            // Session ended — switch back to local
            updateSidebar(path: workspace.currentDirectory)
        }
    }

    func paneView(_ paneView: PaneView, remoteConnectionFailed session: RemoteSessionType, paneID: UUID) {
        guard let workspace = activeWorkspace, workspace.activePaneID == paneID else { return }
        guard isRemoteSidebar, activeRemoteSession == session else { return }

        clearSidebar()

        let failView = NSHostingView(rootView: RemoteConnectionFailedView(session: session))
        failView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(failView)

        NSLayoutConstraint.activate([
            failView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            failView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            failView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            failView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])
    }

    func paneView(_ paneView: PaneView, sessionEnded paneID: UUID) {
        guard let workspace = activeWorkspace else { return }

        // Focus this pane first so smartClose acts on the right one
        if workspace.activePaneID != paneID {
            workspace.activePaneID = paneID
        }
        smartCloseAction(nil)
    }

    // MARK: - Actions

    @objc private func newWorkspaceAction(_ sender: Any?) {
        openWorkspace(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @objc private func openFolderAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open as a workspace"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openWorkspace(path: url.path)
        }
    }











    @objc private func newTabAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let pv = paneViews[workspace.activePaneID] else { return }
        let cwd = pane.activeSession?.currentDirectory ?? workspace.folderPath
        pv.addNewTab(workingDirectory: cwd)
    }

    @objc private func smartCloseAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let pv = paneViews[workspace.activePaneID] else { return }

        if pane.tabs.count > 1 {
            // Multiple tabs: close the active tab (undoable)
            let item = ClosedItem.tab(
                paneID: workspace.activePaneID,
                workingDirectory: pane.activeTab?.workingDirectory ?? workspace.folderPath,
                index: pane.activeTabIndex
            )
            pushUndo(item)
            pv.closeTab(at: pane.activeTabIndex)
            refreshStatusBar()
        } else if workspace.panes.count > 1 {
            // Multiple panes but single tab: close the pane (undoable)
            let cwd = pane.activeSession?.currentDirectory ?? pane.activeTab?.workingDirectory ?? workspace.folderPath
            // Determine split direction from the tree
            let direction = findSplitDirection(for: workspace.activePaneID, in: workspace.splitTree)
            let siblingID = findSiblingID(for: workspace.activePaneID, in: workspace.splitTree)
            let item = ClosedItem.pane(
                siblingPaneID: siblingID ?? workspace.activePaneID,
                workingDirectory: cwd,
                direction: direction ?? .horizontal
            )
            pushUndo(item)
            closePaneAction(nil)
        } else if appState.workspaces.count > 1 {
            // Multiple workspaces: close this workspace
            toolbar(toolbar, didCloseWorkspaceAt: appState.activeWorkspaceIndex)
        } else {
            // Last tab, last pane, last workspace: confirm
            showCloseConfirmation()
        }
    }

    @objc private func reopenTabAction(_ sender: Any?) {
        guard let item = undoStack.popLast(), let workspace = activeWorkspace else { return }

        switch item {
        case .tab(let paneID, let cwd, _):
            let targetPaneID = workspace.pane(for: paneID) != nil ? paneID : workspace.activePaneID
            if let pv = paneViews[targetPaneID] {
                pv.addNewTab(workingDirectory: cwd)
            }

        case .pane(let siblingID, let cwd, let direction):
            // Re-split the sibling pane (or active pane if sibling is gone)
            let targetID = workspace.pane(for: siblingID) != nil ? siblingID : workspace.activePaneID
            window?.makeFirstResponder(nil)

            let newID = workspace.splitPane(targetID, direction: direction)
            // Override the new pane's tab to use the closed pane's cwd
            if let pane = workspace.pane(for: newID) {
                pane.stopAll()
                _ = pane.addTab(workingDirectory: cwd)
            }
            workspace.activePaneID = newID
            splitContainer.update(tree: workspace.splitTree)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Reattach all panes
                for id in workspace.splitTree.leafIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                    }
                }
                if let pv = self.paneViews[newID] {
                    pv.startActiveSession()
                    self.window?.makeFirstResponder(pv.currentTerminalView)
                }
            }
        }
        refreshStatusBar()
    }

    private func pushUndo(_ item: ClosedItem) {
        undoStack.append(item)
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    /// Cache a session so it stays alive for 30 seconds (for undo).
    private func cacheSession(_ session: TerminalSession) {
        sessionCache.append((session: session, expiry: Date().addingTimeInterval(30)))
    }

    private func cleanSessionCache() {
        let now = Date()
        let expired = sessionCache.filter { $0.expiry < now }
        for entry in expired { entry.session.stop() }
        sessionCache.removeAll { $0.expiry < now }
    }

    /// Find the split direction of the parent split containing the given leaf.
    private func findSplitDirection(for leafID: UUID, in tree: SplitTree) -> SplitTree.SplitDirection? {
        switch tree {
        case .leaf:
            return nil
        case .split(let direction, let first, let second, _):
            if first.leafIDs.contains(leafID) || second.leafIDs.contains(leafID) {
                return direction
            }
            return findSplitDirection(for: leafID, in: first) ?? findSplitDirection(for: leafID, in: second)
        }
    }

    /// Find the sibling leaf ID for a given leaf in the split tree.
    private func findSiblingID(for leafID: UUID, in tree: SplitTree) -> UUID? {
        switch tree {
        case .leaf:
            return nil
        case .split(_, let first, let second, _):
            if case .leaf(let id) = first, id == leafID {
                return second.leafIDs.first
            }
            if case .leaf(let id) = second, id == leafID {
                return first.leafIDs.first
            }
            return findSiblingID(for: leafID, in: first) ?? findSiblingID(for: leafID, in: second)
        }
    }

    private func showCloseConfirmation() {
        guard let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Close Exterm?"
        alert.informativeText = "This will end all terminal sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.window?.close()
            }
        }
    }

    @objc private func closePaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let paneID = workspace.activePaneID

        // Remove the closed pane's view from cache
        let closedPV = paneViews.removeValue(forKey: paneID)
        closedPV?.currentTerminalView?.terminal = nil

        if workspace.closePane(paneID) {
            let validIDs = Set(workspace.splitTree.leafIDs)

            for id in paneViews.keys where !validIDs.contains(id) {
                paneViews.removeValue(forKey: id)
            }

            splitContainer.update(tree: workspace.splitTree)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let ws = self.activeWorkspace else { return }
                for id in validIDs {
                    if let pv = self.paneViews[id] {
                        pv.startActiveSession()
                        pv.layoutTerminalView()
                        pv.currentTerminalView?.needsDisplay = true
                    }
                }
                if let pv = self.paneViews[ws.activePaneID] {
                    self.window?.makeFirstResponder(pv.currentTerminalView)
                }
            }
        } else {
            toolbar(toolbar, didCloseWorkspaceAt: appState.activeWorkspaceIndex)
        }
    }

    @objc private func toggleSidebarAction(_ sender: Any?) {
        sidebarVisible.toggle()
        if sidebarVisible {
            mainSplitView.addSubview(sidebarContainer)
            mainSplitView.adjustSubviews()
            mainSplitView.setPosition(mainSplitView.bounds.width - 240, ofDividerAt: 0)
        } else {
            sidebarContainer.removeFromSuperview()
        }
        for (_, pv) in paneViews {
            pv.currentTerminalView?.needsDisplay = true
            pv.currentTerminalView?.needsLayout = true
        }
        refreshToolbar()
    }

    @objc private func splitVerticalAction(_ sender: Any?) {
        splitActivePane(direction: .horizontal)
    }

    @objc private func splitHorizontalAction(_ sender: Any?) {
        splitActivePane(direction: .vertical)
    }

    private func splitActivePane(direction: SplitTree.SplitDirection) {
        guard let workspace = activeWorkspace else { return }
        let oldPaneID = workspace.activePaneID
        window?.makeFirstResponder(nil)

        let newID = workspace.splitPane(oldPaneID, direction: direction)
        workspace.activePaneID = newID
        splitContainer.update(tree: workspace.splitTree)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Reattach the original pane's session to its (rebuilt) view
            if let oldPV = self.paneViews[oldPaneID] {
                oldPV.startActiveSession()
            }
            // Start the new pane's session
            if let newPV = self.paneViews[newID] {
                newPV.startActiveSession()
                self.window?.makeFirstResponder(newPV.currentTerminalView)
            }
        }
    }

    @objc private func showSettingsAction(_ sender: Any?) {
        SettingsWindowController.shared.showSettings()
    }

    // MARK: - Terminal Shortcuts

    @objc private func clearScreenAction(_ sender: Any?) {
        // Cmd+K: send clear (like Terminal.app)
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let session = pane.activeSession else { return }
        // Send form-feed to clear, then redraw prompt
        if let data = "\u{0C}".data(using: .utf8) {
            session.writeToPTY(data)
        }
    }

    @objc private func clearScrollbackAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let session = pane.activeSession else { return }
        // Send CSI 3J to clear scrollback + CSI 2J + CSI H to clear screen
        if let data = "\u{1B}[3J\u{1B}[2J\u{1B}[H".data(using: .utf8) {
            session.writeToPTY(data)
        }
    }

    @objc private func copyAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
              let pv = paneViews[workspace.activePaneID],
              let tv = pv.currentTerminalView,
              let text = tv.selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        tv.clearSelection()
    }

    @objc private func selectAllAction(_ sender: Any?) {
        guard let workspace = activeWorkspace,
              let pv = paneViews[workspace.activePaneID],
              let tv = pv.currentTerminalView else { return }
        tv.selectAll()
    }

    @objc private func focusNextPaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let ids = workspace.splitTree.leafIDs
        guard ids.count > 1 else { return }
        if let idx = ids.firstIndex(of: workspace.activePaneID) {
            let next = ids[(idx + 1) % ids.count]
            workspace.activePaneID = next
            if let pv = paneViews[next] {
                window?.makeFirstResponder(pv.currentTerminalView)
            }
        }
    }

    @objc private func focusPrevPaneAction(_ sender: Any?) {
        guard let workspace = activeWorkspace else { return }
        let ids = workspace.splitTree.leafIDs
        guard ids.count > 1 else { return }
        if let idx = ids.firstIndex(of: workspace.activePaneID) {
            let prev = ids[(idx - 1 + ids.count) % ids.count]
            workspace.activePaneID = prev
            if let pv = paneViews[prev] {
                window?.makeFirstResponder(pv.currentTerminalView)
            }
        }
    }

    @objc private func increaseFontSizeAction(_ sender: Any?) {
        let current = AppSettings.shared.fontSize
        if current < 32 { AppSettings.shared.fontSize = current + 1 }
    }

    @objc private func decreaseFontSizeAction(_ sender: Any?) {
        let current = AppSettings.shared.fontSize
        if current > 8 { AppSettings.shared.fontSize = current - 1 }
    }

    @objc private func resetFontSizeAction(_ sender: Any?) {
        AppSettings.shared.fontSize = 14
    }

    func pastePathToActivePane(_ path: String) {
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let session = pane.activeSession else { return }
        let escaped = shellEscape(path)
        if let data = escaped.data(using: .utf8) {
            session.writeToPTY(data)
        }
    }

    /// Send raw text to the active terminal (no escaping).
    func sendRawToActivePane(_ text: String) {
        guard let workspace = activeWorkspace,
              let pane = workspace.pane(for: workspace.activePaneID),
              let session = pane.activeSession else { return }
        if let data = text.data(using: .utf8) {
            session.writeToPTY(data)
        }
    }

    private func openDirectoryInNewTab(_ path: String) {
        guard let workspace = activeWorkspace,
              let pv = paneViews[workspace.activePaneID] else { return }
        pv.addNewTab(workingDirectory: path)
        refreshStatusBar()
    }

    private func openDirectoryInNewPane(_ path: String) {
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let pv = self.paneViews[newID] {
                pv.startActiveSession()
                self.window?.makeFirstResponder(pv.currentTerminalView)
            }
            self.refreshStatusBar()
        }
    }
}
