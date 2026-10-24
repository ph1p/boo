import Combine
import SwiftUI

/// Built-in local file tree plugin. Shows the file explorer for local directories.
@MainActor
final class LocalFileTreePlugin: BooPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree-local",
        name: "Files",
        version: "1.0.0",
        icon: "folder",
        description: "File explorer for local directories",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: [
            PluginManifest.SettingManifest(
                key: "showHiddenFiles", type: .bool, label: "Show hidden files",
                defaultValue: AnyCodableValue(false), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "showIcons", type: .bool, label: "Show file icons",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "showPath", type: .bool, label: "Show current path",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "showProcess", type: .bool, label: "Show running process",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "showFilterBar", type: .bool, label: "Show filter bar",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "showNavigationBar", type: .bool, label: "Show navigation bar",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "gitDecorations", type: .bool, label: "Show git status",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "dimIgnored", type: .bool, label: "Dim git-ignored files",
                defaultValue: AnyCodableValue(true), options: nil, group: "Display"),
            PluginManifest.SettingManifest(
                key: "navigationMode", type: .string, label: "Folder navigation",
                description: "Browse moves only the explorer (⌥↑ up, ⌥↓ into, ⌥←/⌥→ back/forward); "
                    + "cd types the command into the terminal.",
                defaultValue: AnyCodableValue(ExplorerNavigationMode.browse.rawValue),
                options: nil, group: "Navigation", choices: ExplorerNavigationMode.choices),
            PluginManifest.SettingManifest(
                key: "followTerminal", type: .bool, label: "Follow terminal directory changes",
                description: "When the shell changes directory, a detached explorer jumps back to it.",
                defaultValue: AnyCodableValue(true), options: nil, group: "Navigation"),
            PluginManifest.SettingManifest(
                key: "editorFilePatterns", type: .string,
                label: "Open in editor (file patterns)",
                defaultValue: AnyCodableValue(ContentType.builtInEditorFilePatterns),
                options: "editorFilePatterns", group: "File Opening"),
            PluginManifest.SettingManifest(
                key: "markdownOpenMode", type: .string,
                label: "Open markdown files as",
                defaultValue: AnyCodableValue("preview"),
                options: "markdownOpenMode", group: "File Opening", choices: MarkdownOpenMode.choices),
            PluginManifest.SettingManifest(
                key: "imageOpenMode", type: .string,
                label: "Open images as",
                defaultValue: AnyCodableValue("imageViewer"),
                options: nil, group: "File Opening", choices: ImageOpenMode.choices),
            PluginManifest.SettingManifest(
                key: "textOpenMode", type: .string,
                label: "Open text files as",
                defaultValue: AnyCodableValue("editor"),
                options: nil, group: "File Opening", choices: TextOpenMode.choices),
            PluginManifest.SettingManifest(
                key: "htmlOpenInBrowser", type: .bool,
                label: "Open HTML files in browser",
                defaultValue: AnyCodableValue(false), options: nil, group: "File Opening"),
            PluginManifest.SettingManifest(
                key: "pdfOpenInBrowser", type: .bool,
                label: "Open PDF files in browser",
                defaultValue: AnyCodableValue(true), options: nil, group: "File Opening")
        ]
    )

    /// Cached file tree roots keyed by path for instant switching.
    private var cachedRoots: [String: FileTreeNode] = [:]
    private var fileWatcher: FileSystemWatcher?
    /// Path the live watcher is bound to, so repeat setup calls are no-ops.
    private var watchedPath: String?
    /// Coalesce FS-event bursts (build output, git operations, node_modules) into one
    /// tree refresh instead of one walk per event.
    private let refreshDebouncer = Debouncer(delay: 0.2)
    /// Directories named by FS events since the last refresh ran.
    private var pendingChangedDirs: Set<String> = []
    /// Roots with a `git status` run in flight / a follow-up run requested.
    private var gitRefreshInFlight: Set<String> = []
    private var gitRefreshQueued: Set<String> = []

    /// FileSystemWatcher self-retains while running (passRetained in start()), so its own
    /// deinit never fires — the owner must stop() it or the FSEventStream leaks per window.
    /// The pending refresh captures `self` weakly, so the debouncer needs no cancel here
    /// (a non-Sendable `Debouncer` can't be touched from a nonisolated deinit anyway).
    deinit {
        fileWatcher?.stop()
    }

    /// Open folders per root path — see `ExpandedStateStore` for why the key is the path.
    private var expandedState = ExpandedStateStore()
    /// Row actions, built once and reused — only `isAIAgentRunning` varies per cycle.
    private var treeActions: FileTreeActions?
    /// Root shown per terminal on the last cycle, to detect a context switch.
    private var shownRoot: [UUID: String] = [:]
    /// Each terminal's cwd as of the last cycle. Navigation closures read it at call time,
    /// so a tree view kept across cycles never acts on a stale cwd.
    private var latestCwd: [UUID: String] = [:]
    /// Set when the watcher reports its root deleted/renamed: the next cycle re-checks that
    /// the browsed folder still exists instead of stat-ing it every cycle.
    private var rootMaybeGone = false
    /// Explorer navigation per terminal — lets the tree browse away from the shell's cwd.
    private var browseStates: [UUID: FileTreeBrowseState] = [:]
    /// The last terminal ID we rendered for, so we can save state on switch.
    private var lastTerminalID: UUID?

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { true }

    var subscribedEvents: Set<PluginEvent> {
        [.cwdChanged, .remoteSessionChanged, .focusChanged, .processChanged, .terminalClosed]
    }

    func terminalClosed(terminalID: UUID) {
        shownRoot.removeValue(forKey: terminalID)
        latestCwd.removeValue(forKey: terminalID)
        browseStates.removeValue(forKey: terminalID)
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        let dirName = (rootPath(for: context.terminal) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Browsing

    /// The folder the explorer shows for a terminal: its cwd, unless browsed away.
    func rootPath(for terminal: TerminalContext) -> String {
        browseStates[terminal.terminalID]?.root(terminalCwd: terminal.cwd) ?? terminal.cwd
    }

    /// Apply a navigation step (handed the terminal's cwd) to a terminal's browse state and
    /// redraw if the root moved. The redraw re-points the watcher at the new root.
    func updateBrowseState(
        _ terminalID: UUID, terminalCwd: String, _ change: (inout FileTreeBrowseState, String) -> Void
    ) {
        var state = browseStates[terminalID] ?? FileTreeBrowseState()
        let before = state
        change(&state, terminalCwd)
        guard state != before else { return }
        guard FileManager.default.fileExists(atPath: state.root(terminalCwd: terminalCwd)) else {
            BooAlert.showTransient("Folder no longer exists")
            return
        }
        browseStates[terminalID] = state
        onRequestCycleRerun?()
    }

    /// Make `path` the root for a terminal, per the navigation-mode setting. `cd` mode falls
    /// back to browsing while an AI agent owns the terminal (the text would hit its prompt).
    func open(_ path: String, terminal: TerminalContext, canSendToTerminal: Bool) {
        open(path, terminalID: terminal.terminalID, terminalCwd: terminal.cwd, canSendToTerminal: canSendToTerminal)
    }

    private func open(_ path: String, terminalID: UUID, terminalCwd: String, canSendToTerminal: Bool) {
        if AppSettings.shared.explorerNavigationMode == .terminal && canSendToTerminal {
            cdTerminal(to: path, terminalID: terminalID, terminalCwd: terminalCwd)
        } else {
            updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.browse(to: path, terminalCwd: $1) }
        }
    }

    /// Type `cd` into the terminal and re-link the explorer, which then follows the shell there.
    private func cdTerminal(to path: String, terminalID: UUID, terminalCwd: String) {
        actions?.sendToTerminal?(Self.cdCommand(path))
        updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.attach(terminalCwd: $1) }
    }

    private static func cdCommand(_ path: String) -> String { "cd \(shellEscape(path))\r" }

    /// The bar's path label: relative to the terminal folder when inside it, else
    /// `~`-abbreviated. Also part of the navigation generation key.
    static func displayPath(root: String, terminalCwd cwd: String) -> String {
        if root == cwd { return (root as NSString).lastPathComponent }
        if !cwd.isEmpty, root.hasPrefix(cwd + "/") { return "./" + String(root.dropFirst(cwd.count + 1)) }
        return abbreviatePath(root)
    }

    /// Closures capture only the terminal's ID and read its cwd/root at call time, so a view
    /// kept across cycles (same generation) still navigates from where the shell is now.
    private func makeNavigation(context: PluginContext, canSendToTerminal canSend: Bool) -> FileTreeNavigation {
        let tid = context.terminal.terminalID
        let cwd = context.terminal.cwd
        let state = browseStates[tid] ?? FileTreeBrowseState()
        let step: (@escaping (inout FileTreeBrowseState, String) -> Void) -> @MainActor () -> Void = { change in
            { [weak self] in self?.withLiveCwd(tid) { $0.updateBrowseState(tid, terminalCwd: $1, change) } }
        }
        return FileTreeNavigation(
            mode: AppSettings.shared.explorerNavigationMode,
            displayPath: Self.displayPath(root: state.root(terminalCwd: cwd), terminalCwd: cwd),
            isDetached: state.isDetached,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward,
            canSendToTerminal: canSend,
            open: { [weak self] path in
                self?.withLiveCwd(tid) { $0.open(path, terminalID: tid, terminalCwd: $1, canSendToTerminal: canSend) }
            },
            browse: { path in step { $0.browse(to: path, terminalCwd: $1) }() },
            goBack: step { $0.goBack(terminalCwd: $1) },
            goForward: step { $0.goForward(terminalCwd: $1) },
            attach: step { $0.attach(terminalCwd: $1) },
            cdTerminalHere: { [weak self] in
                self?.withLiveCwd(tid) { plugin, cwd in
                    let root = plugin.browseStates[tid]?.root(terminalCwd: cwd) ?? cwd
                    plugin.cdTerminal(to: root, terminalID: tid, terminalCwd: cwd)
                }
            }
        )
    }

    private func withLiveCwd(_ tid: UUID, _ body: (LocalFileTreePlugin, String) -> Void) {
        guard let cwd = latestCwd[tid] else { return }
        body(self, cwd)
    }

    // MARK: - Sidebar Tab (two sections: file tree + folder info)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }
        guard let treeView = makeDetailView(context: context) else { return nil }
        let title = sectionTitle(context: context) ?? manifest.name
        let cwd = rootPath(for: context.terminal)

        // Generations must change only when the section's *content* changes, not on
        // every plugin cycle: a changed generation swaps the hosting view's rootView,
        // which resets scroll position and SwiftUI view state. The tree view observes
        // its root node directly, so only the root path and the AI flag baked into the
        // row actions matter here.
        let isAIAgent = FileTreeActions.isAIAgentContext(context)
        let treeSection = SidebarSection(
            id: manifest.id,
            name: title,
            icon: manifest.icon,
            content: treeView,
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(for: [cwd, isAIAgent ? "ai" : "plain", navigationKey(context)])
        )
        let infoSection = SidebarSection(
            id: "\(manifest.id).info",
            name: "Folder Info",
            icon: "info.circle",
            content: AnyView(FolderInfoView(path: cwd, fontScale: context.fontScale, theme: context.theme)),
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(for: [cwd])
        )
        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: [treeSection, infoSection]
        )
    }

    /// Nav-bar state baked into the generation: Back/Forward enablement and the linked
    /// indicator change without the root moving (e.g. re-linking to the same folder).
    /// Only what the bar draws — a shell `cd` that leaves the bar unchanged keeps the view.
    private func navigationKey(_ context: PluginContext) -> String {
        let cwd = context.terminal.cwd
        let state = browseStates[context.terminal.terminalID] ?? FileTreeBrowseState()
        let path = Self.displayPath(root: state.root(terminalCwd: cwd), terminalCwd: cwd)
        let mode = AppSettings.shared.explorerNavigationMode.rawValue
        return "\(state.isDetached)|\(state.canGoBack)|\(state.canGoForward)|\(path)|\(mode)"
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        // ~20 closures, identical on every cycle apart from the AI flag — build them once
        // and only re-stamp the flag. The closures read `self.actions` live, so a later
        // `PluginRegistry.actions` reassignment still reaches them.
        if treeActions == nil { treeActions = buildTreeActions() }
        let isAIAgent = FileTreeActions.isAIAgentContext(context)
        treeActions?.isAIAgentRunning = isAIAgent
        guard let treeActions else { return nil }

        let tid = context.terminal.terminalID
        // Existence is only in doubt on a context switch (the folder may have gone while
        // another terminal was shown) or after the watcher saw its root change.
        let checkExists = tid != lastTerminalID || rootMaybeGone
        rootMaybeGone = false
        var state = browseStates[tid] ?? FileTreeBrowseState()
        state.reconcile(
            terminalCwd: context.terminal.cwd, follow: AppSettings.shared.explorerFollowTerminal,
            folderExists: { !checkExists || FileManager.default.fileExists(atPath: $0) })
        browseStates[tid] = state
        latestCwd[tid] = context.terminal.cwd
        let cwd = state.root(terminalCwd: context.terminal.cwd)
        let isSameTerminalAndCwd = (tid == lastTerminalID && shownRoot[tid] == cwd)

        if !isSameTerminalAndCwd {
            // The root we're leaving keeps its open folders under its own path key.
            snapshotExpandedState(except: cwd)
            setupWatcher(for: cwd)
        }
        let (root, wasCreated) = getOrCreateRoot(for: cwd)

        // On context switch, reload the root's children — the root may be a cached
        // node whose children are nil (e.g. after eviction) or stale, and SwiftUI's
        // onAppear doesn't fire when rootView is replaced in-place via
        // NSHostingView.rootView, so we must trigger the load here.
        // A brand-new root already loaded in getOrCreateRoot; don't load twice.
        if !isSameTerminalAndCwd && !wasCreated {
            root.loadChildrenAsync()
        }
        if !isSameTerminalAndCwd { refreshGitStatus(root) }

        // Only restore on terminal/CWD switch — skipping on same-context re-renders
        // prevents save→restore from collapsing folders the user just opened.
        if !isSameTerminalAndCwd,
            let saved = expandedState.paths(for: cwd)
        {
            root.restoreExpanded(saved)
        }
        lastTerminalID = tid
        shownRoot[tid] = cwd

        let navigation = makeNavigation(context: context, canSendToTerminal: !isAIAgent)
        return AnyView(FileTreeView(root: root, actions: treeActions, navigation: navigation))
    }

    private func buildTreeActions() -> FileTreeActions {
        // Resolved on each invocation rather than captured: `PluginRegistry.actions` is
        // reassigned after registration, and these closures outlive that assignment.
        let act: @MainActor () -> PluginActions? = { [weak self] in self?.actions }
        return FileTreeActions(
            onFileClicked: { path in
                let ext = (path as NSString).pathExtension.lowercased()
                let filename = ((path as NSString).lastPathComponent).lowercased()
                let isImage = ContentType.imageExtensions.contains(ext)
                let isMarkdown = ContentType.markdownExtensions.contains(ext)
                let isHTML = ContentType.htmlExtensions.contains(ext)
                let isPDF = ContentType.pdfExtensions.contains(ext)
                let isEditorFile = ContentType.isEditorFilePattern(filename: filename)

                let htmlOpenInBrowser = AppSettings.shared.pluginBool(
                    "file-tree-local", "htmlOpenInBrowser", default: false)
                let pdfOpenInBrowser = AppSettings.shared.pluginBool(
                    "file-tree-local", "pdfOpenInBrowser", default: true)
                if isPDF && pdfOpenInBrowser {
                    act()?.openTab?(.browser(url: URL(fileURLWithPath: path)))
                } else if isPDF {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else if isHTML && htmlOpenInBrowser {
                    act()?.openTab?(.browser(url: URL(fileURLWithPath: path)))
                } else if isImage {
                    let imageModeRaw = AppSettings.shared.pluginString(
                        "file-tree-local", "imageOpenMode", default: "imageViewer")
                    let imageMode = ImageOpenMode(rawValue: imageModeRaw) ?? .imageViewer
                    switch imageMode {
                    case .kitty:
                        act()?.displayImageInTerminal?(path, false)
                    case .external:
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    case .multiContent, .imageViewer:
                        act()?.openTab?(.file(path: path))
                    }
                } else if isMarkdown {
                    act()?.openTab?(.file(path: path))
                } else if isEditorFile {
                    let textModeRaw = AppSettings.shared.pluginString(
                        "file-tree-local", "textOpenMode", default: "editor")
                    let textMode = TextOpenMode(rawValue: textModeRaw) ?? .editor
                    switch textMode {
                    case .terminalEditor:
                        let parentDir = (path as NSString).deletingLastPathComponent
                        act()?.openDirectoryInNewTab?(parentDir)
                        let configured = AppSettings.shared.fileEditorCommand.trimmingCharacters(
                            in: .whitespaces
                        )
                        let editorCmd =
                            configured.isEmpty
                            ? (ProcessInfo.processInfo.environment["EDITOR"] ?? "vi")
                            : configured
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            act()?.sendToTerminal?("\(editorCmd) \(shellEscape(path))\r")
                        }
                    case .external:
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    case .editor, .multiContent:
                        act()?.openTab?(.file(path: path))
                    }
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            },
            onPastePath: { path in
                act()?.pastePath(path)
            },
            onOpenInTab: { path in
                act()?.openDirectoryInNewTab?(path)
            },
            onOpenInPane: { path in
                act()?.openDirectoryInNewPane?(path)
            },
            onOpenFileInTab: { path in
                act()?.openTab?(.file(path: path))
            },
            onOpenFileInPane: { path in
                act()?.openFileInNewPane?(path)
            },
            onOpenFileInBrowser: { path in
                act()?.openTab?(.browser(url: URL(fileURLWithPath: path)))
            },
            onCopyPath: { path in
                act()?.handle(DSLAction(type: "copy", path: path, command: nil, text: nil))
            },
            onRevealInFinder: { path in
                act()?.handle(DSLAction(type: "reveal", path: path, command: nil, text: nil))
            },
            onRunCommand: { cmd in
                act()?.sendToTerminal?(cmd)
            },
            onNavigate: { path in
                act()?.sendToTerminal?(Self.cdCommand(path))
            },
            onMoveToTrash: { [weak self] paths in
                guard !paths.isEmpty else { return }
                NSWorkspace.shared.recycle(paths.map { URL(fileURLWithPath: $0) }) { _, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        for (rootPath, root) in self.cachedRoots
                        where paths.contains(where: { $0.hasPrefix(rootPath) }) {
                            root.refreshAll()
                        }
                    }
                }
            },
            onRename: { oldPath, newName in
                guard !newName.contains("/"), !newName.contains("..") else {
                    BooAlert.showTransient("Invalid name")
                    return
                }
                let parentDir = (oldPath as NSString).deletingLastPathComponent
                let newPath = (parentDir as NSString).appendingPathComponent(newName)
                guard oldPath != newPath else { return }
                do {
                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                } catch {
                    BooAlert.showTransient("Rename failed: \(error.localizedDescription)")
                }
            },
            onMove: { sourcePath, destinationDir in
                let fileName = (sourcePath as NSString).lastPathComponent
                let destPath = (destinationDir as NSString).appendingPathComponent(fileName)
                guard sourcePath != destPath,
                    !destinationDir.hasPrefix(sourcePath + "/")
                else { return }
                do {
                    try FileManager.default.moveItem(atPath: sourcePath, toPath: destPath)
                } catch {
                    BooAlert.showTransient("Move failed: \(error.localizedDescription)")
                }
            },
            onCreateFolder: { parentPath in
                var folderName = "New Folder"
                var destPath = (parentPath as NSString).appendingPathComponent(folderName)
                var counter = 2
                while FileManager.default.fileExists(atPath: destPath) {
                    folderName = "New Folder \(counter)"
                    destPath = (parentPath as NSString).appendingPathComponent(folderName)
                    counter += 1
                }
                do {
                    try FileManager.default.createDirectory(
                        atPath: destPath, withIntermediateDirectories: false)
                } catch {
                    BooAlert.showTransient("Create folder failed: \(error.localizedDescription)")
                }
            },
            onCreateFile: { parentPath in
                var fileName = "New File"
                var destPath = (parentPath as NSString).appendingPathComponent(fileName)
                var counter = 2
                while FileManager.default.fileExists(atPath: destPath) {
                    fileName = "New File \(counter)"
                    destPath = (parentPath as NSString).appendingPathComponent(fileName)
                    counter += 1
                }
                FileManager.default.createFile(atPath: destPath, contents: nil)
            },
            onDuplicate: { path in
                let parentDir = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                var candidate = "\(stem) copy\(suffix)"
                var destPath = (parentDir as NSString).appendingPathComponent(candidate)
                var counter = 2
                while FileManager.default.fileExists(atPath: destPath) {
                    candidate = "\(stem) copy \(counter)\(suffix)"
                    destPath = (parentDir as NSString).appendingPathComponent(candidate)
                    counter += 1
                }
                do {
                    try FileManager.default.copyItem(atPath: path, toPath: destPath)
                } catch {
                    BooAlert.showTransient("Duplicate failed: \(error.localizedDescription)")
                }
            },
            onCopyImage: { path in
                guard let image = NSImage(contentsOfFile: path) else {
                    BooAlert.showTransient("Could not load image")
                    return
                }
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.writeObjects([image]) {
                    BooAlert.showTransient("Could not copy image to clipboard")
                }
            },
            onReferenceInAI: { path in
                act()?.sendToTerminal?("@\(path) ")
            },
            onSetFileRoot: { [weak self] _ in
                guard let self else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Set as Root"
                panel.begin { [weak self] response in
                    guard response == .OK, let url = panel.url else { return }
                    FolderBookmarkStore.shared.save(url)
                    self?.cachedRoots.removeAll()
                    self?.hostActions?.setWorkspaceRoot?(url.path)
                }
            },
            isAIAgentRunning: false
        )
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        // A detached explorer keeps watching the folder it shows; if "follow terminal"
        // re-links it, the next cycle's makeDetailView re-points the watcher.
        setupWatcher(for: rootPath(for: context))
    }

    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        if session != nil {
            stopWatching()
        } else {
            setupWatcher(for: rootPath(for: context))
        }
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        let root = rootPath(for: context)
        setupWatcher(for: root)
        // A commit or checkout in the terminal changes status without touching the
        // worktree files the watcher reports, so re-read git on focus too.
        if let node = cachedRoots[root] { refreshGitStatus(node) }
    }

    func processChanged(name: String, context: TerminalContext) {
        // No action needed — makeDetailView reads the current processName
        // from the context on every plugin cycle, so isAIAgentRunning is
        // always up to date.  Do NOT call onRequestCycleRerun here:
        // processChanged is invoked *during* a plugin cycle, so triggering
        // another cycle would cause infinite recursion.
    }

    // MARK: - Internal

    /// Save expanded state for the cached roots, so an eviction or a later revisit of
    /// any of those directories restores the same open folders.
    /// `except` skips a root that is staying put and whose state is therefore still live.
    private func snapshotExpandedState(except keptPath: String? = nil) {
        expandedState.snapshot(roots: cachedRoots, except: keptPath) { $0.expandedPaths() }
    }

    /// Test hook: the cached root node for a path, if one exists.
    func cachedRoot(for path: String) -> FileTreeNode? { cachedRoots[path] }

    /// Returns the cached root for `path`, plus whether it was freshly created
    /// (a new root has already loaded its children, so callers must not reload).
    private func getOrCreateRoot(for path: String) -> (root: FileTreeNode, wasCreated: Bool) {
        if let cached = cachedRoots[path] { return (cached, false) }
        let name = (path as NSString).lastPathComponent
        let root = FileTreeNode(name: name, path: path, isDirectory: true)
        // Sync on purpose: one top-level listing for the first paint. Async here would
        // show an empty explorer for a frame on every new directory.
        root.loadChildren()
        root.isExpanded = true
        cachedRoots[path] = root
        setupWatcher(for: path)
        if cachedRoots.count > 10 {
            // Persist what we're about to drop, then evict all entries except the
            // current path to bound cache growth.
            snapshotExpandedState(except: path)
            cachedRoots = cachedRoots.filter { $0.key == path }
        }
        return (root, true)
    }

    private func setupWatcher(for path: String) {
        // Watching the same path already — keep the live stream. Tearing it down and
        // recreating it on every focus/cwd event costs an FSEventStream churn and an
        // immediate full refresh of every cached root.
        guard path != watchedPath else { return }
        stopWatching()
        guard !path.isEmpty else { return }
        watchedPath = path
        // Reads `watchedPath` rather than capturing the path, so re-pointing the
        // watcher never leaves a stale path captured in a live closure.
        fileWatcher = FileSystemWatcher(
            path: path,
            onRootChanged: { [weak self] in self?.watchedRootChanged() },
            onChange: { [weak self] changed in self?.scheduleRefresh(changed: changed) })
        fileWatcher?.start()
    }

    /// The watched root was deleted, renamed or moved: re-check it on the next cycle.
    func watchedRootChanged() {
        rootMaybeGone = true
        onRequestCycleRerun?()
    }

    /// Tear down the live watcher and any refresh it had queued.
    private func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
        watchedPath = nil
        refreshDebouncer.cancel()
        pendingChangedDirs.removeAll()
    }

    /// Changed paths accumulate across the debounce window so a burst still refreshes
    /// every directory it touched, and only those.
    private func scheduleRefresh(changed: [String]) {
        for p in changed {
            // The event path may be the directory itself (create/delete of a subdir) or a
            // file inside it; both cases mean "re-read the parent", and a directory event
            // can also mean "re-read that directory". Recording both avoids a stat call.
            pendingChangedDirs.insert(p)
            pendingChangedDirs.insert((p as NSString).deletingLastPathComponent)
        }
        refreshDebouncer.schedule { [weak self] in
            guard let self, let path = self.watchedPath else { return }
            let dirs = self.pendingChangedDirs
            self.pendingChangedDirs.removeAll()
            // Refresh the cached roots that overlap the watched path, walking only the
            // directories the events named.
            for (rootPath, root) in self.cachedRoots
            where path.hasPrefix(rootPath) || rootPath.hasPrefix(path) {
                root.refresh(changedDirs: dirs)
                self.refreshGitStatus(root)
            }
            FolderInfoCache.shared.invalidate(path)
        }
    }

    /// Re-read `git status` for a root off the main thread. One run per root at a time;
    /// a request arriving mid-run queues exactly one follow-up so the result is never stale.
    private func refreshGitStatus(_ root: FileTreeNode) {
        guard AppSettings.shared.explorerGitDecorations else {
            root.gitStatus = nil
            return
        }
        let path = root.path
        guard !gitRefreshInFlight.contains(path) else {
            gitRefreshQueued.insert(path)
            return
        }
        gitRefreshInFlight.insert(path)
        Task { [weak self, weak root] in
            let status = await Task.detached(priority: .utility) {
                FileTreeGitStatus.load(rootPath: path)
            }.value
            guard let self else { return }
            self.gitRefreshInFlight.remove(path)
            if let root, root.gitStatus != status { root.gitStatus = status }
            if self.gitRefreshQueued.remove(path) != nil, let root { self.refreshGitStatus(root) }
        }
    }
}
