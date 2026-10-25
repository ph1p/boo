import Combine
import SwiftUI

/// Built-in remote file tree plugin. Shows the file explorer for SSH/Docker sessions.
///
/// Mirrors `LocalFileTreePlugin` on top of the shared `FileTreeView`: the nodes list
/// through a `RemoteFileTreeSource` instead of the local disk, and file operations run
/// as remote shell commands. Display, navigation and file-opening settings are the
/// local plugin's — one explorer configuration for both trees.
@MainActor
final class RemoteFileTreePlugin: BooPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree-remote",
        name: "Files (Remote)",
        version: "1.0.0",
        icon: "externaldrive.connected.to.line.below",
        description: "File explorer for remote sessions",
        when: "env.ssh",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    static let maxCachedRoots = 5

    /// Cached tree roots keyed by `"host:path"` (see `cacheKey`), oldest first.
    private var cachedRemoteRoots: [String: FileTreeNode] = [:]
    private var rootOrder: [String] = []
    /// One source per remote target, shared by every root on it.
    private var sources: [String: RemoteFileTreeSource] = [:]

    /// Open folders per `"host:path"` cache key — see `ExpandedStateStore` for why the
    /// key is the root and not the terminal.
    private var expandedState = ExpandedStateStore()
    /// Row actions, built once and reused — only `isAIAgentRunning` varies per cycle.
    private var treeActions: FileTreeActions?
    /// Cache key shown per terminal on the last cycle, to detect a context switch.
    private var shownKey: [UUID: String] = [:]
    /// Explorer navigation per terminal — lets the tree browse away from the shell's cwd.
    private var browseStates: [UUID: FileTreeBrowseState] = [:]
    /// Each terminal's (tilde-resolved) cwd as of the last cycle. Closures read it at
    /// call time, so a view kept across cycles never acts on stale values.
    private var latestCwd: [UUID: String] = [:]
    /// The last terminal ID we rendered for. Row actions act on its session — the
    /// sidebar only ever shows the focused terminal's tree.
    private var lastTerminalID: UUID?
    /// Roots (by cache key) with a remote `git status` in flight / a follow-up requested.
    private var gitRefreshInFlight: Set<String> = []
    private var gitRefreshQueued: Set<String> = []
    /// Targets with a `~` lookup in flight, so a burst of cycles asks once.
    private var resolvingHome: Set<String> = []

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { true }

    var subscribedEvents: Set<PluginEvent> {
        [.processChanged, .remoteDirectoryListed, .focusChanged, .terminalClosed]
    }

    /// Drop per-terminal state when a terminal closes so the dicts don't grow one entry
    /// per terminal ever opened. The expanded state is keyed by root and outlives it.
    func terminalClosed(terminalID: UUID) {
        shownKey.removeValue(forKey: terminalID)
        browseStates.removeValue(forKey: terminalID)
        latestCwd.removeValue(forKey: terminalID)
        if lastTerminalID == terminalID {
            lastTerminalID = nil
            activeSession = nil
        }
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        let dirName = (rootPath(for: context.terminal) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    /// The tree view observes its root node, so a listing arriving needs no rootView swap
    /// — a swap would reset scroll and view state. Only the root's identity, the AI flag
    /// baked into the row actions, and what the navigation bar draws change the section.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        guard let session = context.terminal.remoteSession else { return 0 }
        let key = Self.cacheKey(for: rootPath(for: context.terminal), session: session)
        let isAIAgent = FileTreeActions.isAIAgentContext(context)
        return SidebarSection.generation(for: [key, isAIAgent ? "ai" : "plain", navigationKey(context)])
    }

    // MARK: - Browsing

    /// The shell's cwd with `~` resolved once the remote home is known.
    private func terminalCwd(for terminal: TerminalContext) -> String {
        let raw = Self.remoteRootPath(for: terminal)
        guard let session = terminal.remoteSession else { return raw }
        return RemoteExplorer.resolveTilde(raw, session: session) ?? raw
    }

    /// The folder the explorer shows for a terminal: its cwd, unless browsed away.
    func rootPath(for terminal: TerminalContext) -> String {
        let cwd = terminalCwd(for: terminal)
        return browseStates[terminal.terminalID]?.root(terminalCwd: cwd) ?? cwd
    }

    private func updateBrowseState(
        _ terminalID: UUID, terminalCwd: String, _ change: (inout FileTreeBrowseState, String) -> Void
    ) {
        var state = browseStates[terminalID] ?? FileTreeBrowseState()
        let before = state
        change(&state, terminalCwd)
        guard state != before else { return }
        browseStates[terminalID] = state
        onRequestCycleRerun?()
    }

    private func open(_ path: String, terminalID: UUID, terminalCwd: String, canSendToTerminal: Bool) {
        if AppSettings.shared.explorerNavigationMode == .terminal && canSendToTerminal {
            cdTerminal(to: path, terminalID: terminalID, terminalCwd: terminalCwd)
        } else {
            updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.browse(to: path, terminalCwd: $1) }
        }
    }

    private func cdTerminal(to path: String, terminalID: UUID, terminalCwd: String) {
        actions?.sendToTerminal?(Self.cdCommand(path))
        updateBrowseState(terminalID, terminalCwd: terminalCwd) { $0.attach(terminalCwd: $1) }
    }

    private static func cdCommand(_ path: String) -> String { "cd \(RemoteExplorer.shellEscPath(path))\r" }

    /// The bar's path label: relative to the terminal folder when inside it, else
    /// abbreviated against the remote home.
    nonisolated static func displayPath(root: String, terminalCwd cwd: String, home: String?) -> String {
        if root == cwd { return (root as NSString).lastPathComponent }
        if !cwd.isEmpty, root.hasPrefix(cwd + "/") { return "./" + String(root.dropFirst(cwd.count + 1)) }
        if let home, root == home { return "~" }
        if let home, root.hasPrefix(home + "/") { return "~" + String(root.dropFirst(home.count)) }
        return root
    }

    private func displayPath(root: String, terminalCwd: String, session: RemoteSessionType) -> String {
        Self.displayPath(
            root: root, terminalCwd: terminalCwd, home: RemoteExplorer.resolveTilde("~", session: session))
    }

    private func navigationKey(_ context: PluginContext) -> String {
        guard let session = context.terminal.remoteSession else { return "" }
        let cwd = terminalCwd(for: context.terminal)
        let state = browseStates[context.terminal.terminalID] ?? FileTreeBrowseState()
        let path = displayPath(root: state.root(terminalCwd: cwd), terminalCwd: cwd, session: session)
        let mode = AppSettings.shared.explorerNavigationMode.rawValue
        return "\(state.isDetached)|\(state.canGoBack)|\(state.canGoForward)|\(path)|\(mode)"
    }

    private func makeNavigation(
        context: PluginContext, session: RemoteSessionType, canSendToTerminal canSend: Bool
    ) -> FileTreeNavigation {
        let tid = context.terminal.terminalID
        let cwd = terminalCwd(for: context.terminal)
        let state = browseStates[tid] ?? FileTreeBrowseState()
        let step: (@escaping (inout FileTreeBrowseState, String) -> Void) -> @MainActor () -> Void = { change in
            { [weak self] in self?.withLiveCwd(tid) { $0.updateBrowseState(tid, terminalCwd: $1, change) } }
        }
        return FileTreeNavigation(
            mode: AppSettings.shared.explorerNavigationMode,
            displayPath: displayPath(root: state.root(terminalCwd: cwd), terminalCwd: cwd, session: session),
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

    private func withLiveCwd(_ tid: UUID, _ body: (RemoteFileTreePlugin, String) -> Void) {
        guard let cwd = latestCwd[tid] else { return }
        body(self, cwd)
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard let session = context.terminal.remoteSession else { return nil }

        if treeActions == nil { treeActions = buildTreeActions() }
        let isAIAgent = FileTreeActions.isAIAgentContext(context)
        treeActions?.isAIAgentRunning = isAIAgent
        guard let treeActions else { return nil }

        resolveHomeIfNeeded(context.terminal, session: session)

        let tid = context.terminal.terminalID
        let cwd = terminalCwd(for: context.terminal)
        var state = browseStates[tid] ?? FileTreeBrowseState()
        // A browsed folder that vanished shows as an unreadable root, so there's no
        // remote existence check here (it would cost a round-trip per cycle).
        state.reconcile(
            terminalCwd: cwd, follow: AppSettings.shared.explorerFollowTerminal, folderExists: { _ in true })
        browseStates[tid] = state
        latestCwd[tid] = cwd
        activeSession = session

        let path = state.root(terminalCwd: cwd)
        let key = Self.cacheKey(for: path, session: session)
        let isSameContext = (tid == lastTerminalID && shownKey[tid] == key)

        if !isSameContext {
            // The root we're leaving keeps its open folders under its own key.
            snapshotExpandedState(except: key)
        }
        let (root, wasCreated) = getOrCreateRoot(for: path, session: session)
        if !isSameContext && !wasCreated { root.loadChildrenAsync() }
        if !isSameContext { refreshGitStatus(root, session: session) }
        // Only restore on terminal/path switch — re-running it on a same-context cycle
        // would collapse a folder the user just opened.
        if !isSameContext, let saved = expandedState.paths(for: key) {
            root.restoreExpanded(saved)
        }
        shownKey[tid] = key
        lastTerminalID = tid

        let navigation = makeNavigation(context: context, session: session, canSendToTerminal: !isAIAgent)
        return AnyView(
            RemoteFileTreeContainer(
                root: root, source: source(for: session), actions: treeActions, navigation: navigation))
    }

    /// Look up the remote `~` once per target, then redraw with absolute paths so the
    /// cache key, git status and navigation all agree on one spelling.
    private func resolveHomeIfNeeded(_ terminal: TerminalContext, session: RemoteSessionType) {
        guard RemoteExplorer.resolveTilde("~", session: session) == nil else { return }
        let target = session.sshConnectionTarget
        guard resolvingHome.insert(target).inserted else { return }
        RemoteExplorer.resolveRemoteHome(session: session) { [weak self] home in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resolvingHome.remove(target)
                guard home != nil else { return }
                // Roots created under the `~` spelling are superseded.
                let tildePrefix = "\(target):~"
                for key in self.cachedRemoteRoots.keys where key.hasPrefix(tildePrefix) {
                    self.removeRoot(key)
                }
                self.onRequestCycleRerun?()
            }
        }
    }

    // MARK: - Actions

    /// The session row actions act on: the terminal the sidebar last rendered.
    private var activeSession: RemoteSessionType?

    private var activeSource: RemoteFileTreeSource? {
        activeSession.map { source(for: $0) }
    }

    private func buildTreeActions() -> FileTreeActions {
        // Resolved on each invocation rather than captured: `PluginRegistry.actions` is
        // reassigned after registration, and these closures outlive that assignment.
        let act: @MainActor () -> PluginActions? = { [weak self] in self?.actions }
        return FileTreeActions(
            onFileClicked: { [weak self] path in
                self?.openFile(path)
            },
            onPastePath: { path in
                act()?.pastePath(path)
            },
            onCopyPath: { path in
                act()?.handle(DSLAction(type: "copy", path: path, command: nil, text: nil))
            },
            onRunCommand: { cmd in
                act()?.sendToTerminal?(cmd)
            },
            onNavigate: { path in
                act()?.sendToTerminal?(Self.cdCommand(path))
            },
            onRename: { [weak self] oldPath, newName in
                guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
                    BooAlert.showTransient("Invalid name")
                    return
                }
                let parent = (oldPath as NSString).deletingLastPathComponent
                let newPath = RemoteFileTreeSource.childPath(parent, newName)
                guard oldPath != newPath else { return }
                self?.runOperation(Self.moveScript(from: oldPath, to: newPath), failure: "Rename", refresh: [parent])
            },
            onMove: { [weak self] sourcePath, destinationDir in
                let name = (sourcePath as NSString).lastPathComponent
                let destPath = RemoteFileTreeSource.childPath(destinationDir, name)
                guard sourcePath != destPath, !destinationDir.hasPrefix(sourcePath + "/") else { return }
                self?.runOperation(
                    Self.moveScript(from: sourcePath, to: destPath), failure: "Move",
                    refresh: [(sourcePath as NSString).deletingLastPathComponent, destinationDir])
            },
            onCreateFolder: { [weak self] parent in
                self?.runOperation(
                    Self.createScript(in: parent, baseName: "New Folder", command: "mkdir -- \"$n\""),
                    failure: "Create folder", refresh: [parent])
            },
            onCreateFile: { [weak self] parent in
                self?.runOperation(
                    Self.createScript(in: parent, baseName: "New File", command: ": > \"$n\""),
                    failure: "Create file", refresh: [parent])
            },
            onDuplicate: { [weak self] path in
                let parent = (path as NSString).deletingLastPathComponent
                self?.runOperation(Self.duplicateScript(path), failure: "Duplicate", refresh: [parent])
            },
            onReferenceInAI: { path in
                act()?.sendToTerminal?("@\(path) ")
            },
            onOpenExternally: { [weak self] path in
                self?.fetchToCache(path) { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
            },
            onDownload: { [weak self] paths in
                self?.download(paths)
            },
            onUpload: { [weak self] localPaths, destinationDir in
                self?.upload(localPaths, to: destinationDir)
            },
            onDelete: { [weak self] paths in
                guard !paths.isEmpty else { return }
                let quoted = paths.map(RemoteExplorer.shellEscPath).joined(separator: " ")
                let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
                self?.runOperation(
                    RemoteFileTreeSource.operationScript("rm -rf -- \(quoted)"), failure: "Delete",
                    refresh: Array(parents))
            },
            onRefresh: { [weak self] rootPath in
                guard let self, let session = self.activeSession,
                    let root = self.cachedRemoteRoots[Self.cacheKey(for: rootPath, session: session)]
                else { return }
                self.refreshGitStatus(root, session: session)
            },
            onFetchInfo: { [weak self] path in
                guard let source = self?.activeSource else { return nil }
                return await source.info(path)
            },
            isAIAgentRunning: false
        )
    }

    /// Open a remote file per the "File Opening" settings: a terminal editor runs on the
    /// remote shell itself; everything else opens a downloaded local copy.
    private func openFile(_ path: String) {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let textMode =
            TextOpenMode(
                rawValue: AppSettings.shared.pluginString("file-tree-local", "textOpenMode", default: "editor"))
            ?? .editor
        if ContentType.isEditorFilePattern(filename: filename), textMode == .terminalEditor,
            treeActions?.isAIAgentRunning == false
        {
            let configured = AppSettings.shared.fileEditorCommand.trimmingCharacters(in: .whitespaces)
            let editor = configured.isEmpty ? "${EDITOR:-vi}" : configured
            actions?.sendToTerminal?("\(editor) \(RemoteExplorer.shellEscPath(path))\r")
            return
        }
        fetchToCache(path) { [weak self] local in
            LocalFileTreePlugin.openFile(local, actions: self?.actions)
        }
    }

    /// Mirror of a remote file under the temp dir, by host and remote path.
    nonisolated static func cachePath(for remotePath: String, session: RemoteSessionType) -> String {
        let host = session.sshConnectionTarget.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("Boo-remote/\(String(host))")
        let relative = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
        return (base as NSString).appendingPathComponent(relative)
    }

    /// Download one file into the temp mirror, then hand over the local path. The copy is
    /// made read-only: edits to it would never reach the remote file.
    private func fetchToCache(_ path: String, then open: @escaping @MainActor (String) -> Void) {
        guard let session = activeSession else { return }
        let local = Self.cachePath(for: path, session: session)
        let folder = (local as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: local)
        RemoteFileTransfer.download(session: session, paths: [path], to: folder) { failure in
            if let failure {
                BooAlert.showTransient("Download failed: \(failure.message)")
                return
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: local, isDirectory: &isDir), !isDir.boolValue {
                try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local)
            }
            open(local)
        }
    }

    /// Save to ~/Downloads, never replacing what is there: stage in a temp folder, then
    /// move each item in under a free name.
    private func download(_ paths: [String]) {
        guard let session = activeSession, !paths.isEmpty else { return }
        let fm = FileManager.default
        let staging = (NSTemporaryDirectory() as NSString).appendingPathComponent("Boo-download-\(UUID().uuidString)")
        let downloads =
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
        BooAlert.showTransient(paths.count == 1 ? "Downloading…" : "Downloading \(paths.count) items…")
        RemoteFileTransfer.download(session: session, paths: paths, to: staging) { failure in
            defer { try? fm.removeItem(atPath: staging) }
            if let failure {
                BooAlert.showTransient("Download failed: \(failure.message)")
                return
            }
            var saved: [URL] = []
            for name in (try? fm.contentsOfDirectory(atPath: staging)) ?? [] {
                let dest = Self.uniquePath(in: downloads, name: name) { fm.fileExists(atPath: $0) }
                do {
                    try fm.moveItem(atPath: (staging as NSString).appendingPathComponent(name), toPath: dest)
                    saved.append(URL(fileURLWithPath: dest))
                } catch {
                    BooAlert.showTransient("Download failed: \(error.localizedDescription)")
                    return
                }
            }
            let label =
                saved.count == 1 ? "Downloaded \(saved[0].lastPathComponent)" : "Downloaded \(saved.count) items"
            BooAlert.showTransient(
                label,
                actions: [
                    BooAlert.ToastAction(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(saved)
                    }
                ])
        }
    }

    /// `name`, or `name 2`, `name 3`… (before the extension) — the first free one.
    nonisolated static func uniquePath(in directory: String, name: String, exists: (String) -> Bool) -> String {
        let first = (directory as NSString).appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var counter = 2
        while true {
            let candidate = (directory as NSString).appendingPathComponent("\(stem) \(counter)\(suffix)")
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    private func upload(_ localPaths: [String], to destination: String) {
        guard let session = activeSession, let source = activeSource, !localPaths.isEmpty else { return }
        guard RemoteFileTransfer.isSupported(session) else {
            BooAlert.showTransient("Upload isn't supported for this session")
            return
        }
        let names = localPaths.map { ($0 as NSString).lastPathComponent }
        Task { [weak self] in
            guard let existing = await source.existingNames(names, in: destination) else {
                BooAlert.showTransient("Remote host unreachable")
                return
            }
            if !existing.isEmpty && !Self.confirmReplace(existing) { return }
            BooAlert.showTransient(localPaths.count == 1 ? "Uploading…" : "Uploading \(localPaths.count) items…")
            RemoteFileTransfer.upload(session: session, paths: localPaths, to: destination) { failure in
                if let failure {
                    BooAlert.showTransient("Upload failed: \(failure.message)")
                } else {
                    BooAlert.showTransient(
                        localPaths.count == 1 ? "Uploaded \(names[0])" : "Uploaded \(localPaths.count) items")
                }
                self?.refreshDirectories([destination])
            }
        }
    }

    private static func confirmReplace(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText =
            names.count == 1
            ? "\u{201C}\(names[0])\u{201D} already exists on the remote host. Replace it?"
            : "\(names.count) items already exist on the remote host. Replace them?"
        alert.informativeText = "Replacing overwrites the remote copies. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Run a file operation remotely, report a failure, then re-read the touched folders.
    private func runOperation(_ script: String, failure label: String, refresh dirs: [String]) {
        guard let source = activeSource else { return }
        Task { [weak self] in
            if let message = await source.perform(script) {
                BooAlert.showTransient("\(label) failed: \(message)")
            }
            self?.refreshDirectories(dirs)
        }
    }

    /// Re-list `dirs` wherever they appear in the active session's trees, and re-read git.
    private func refreshDirectories(_ dirs: [String]) {
        guard let session = activeSession else { return }
        let prefix = "\(Self.cacheHost(for: session)):"
        let changed = Set(dirs)
        for (key, root) in cachedRemoteRoots where key.hasPrefix(prefix) {
            root.refresh(changedDirs: changed)
        }
        if let tid = lastTerminalID, let key = shownKey[tid], let root = cachedRemoteRoots[key] {
            refreshGitStatus(root, session: session)
        }
    }

    // MARK: - Operation scripts

    nonisolated static func moveScript(from source: String, to destination: String) -> String {
        let dest = RemoteExplorer.shellEscPath(destination)
        return RemoteFileTreeSource.operationScript(
            "if [ -e \(dest) ] || [ -L \(dest) ]; then echo 'An item with that name already exists' >&2; false; "
                + "else mv -- \(RemoteExplorer.shellEscPath(source)) \(dest); fi")
    }

    /// Create `baseName`, or `baseName 2`, `baseName 3`… in `parent`; `command` sees the
    /// chosen name as `$n`.
    nonisolated static func createScript(in parent: String, baseName: String, command: String) -> String {
        let base = shellEscape(baseName)
        return RemoteFileTreeSource.operationScript(
            "cd \(RemoteExplorer.shellEscPath(parent)) && n=\(base) && i=2 && "
                + "while [ -e \"$n\" ] || [ -L \"$n\" ]; do n=\(base)\" $i\"; i=$((i+1)); done && \(command)")
    }

    /// `name copy.ext`, then `name copy 2.ext`… — the local tree's naming.
    nonisolated static func duplicateScript(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let s = shellEscape(stem)
        let x = shellEscape(ext.isEmpty ? "" : ".\(ext)")
        return RemoteFileTreeSource.operationScript(
            "cd \(RemoteExplorer.shellEscPath(parent)) && s=\(s) && x=\(x) && n=\"$s copy$x\" && i=2 && "
                + "while [ -e \"$n\" ] || [ -L \"$n\" ]; do n=\"$s copy $i$x\"; i=$((i+1)); done && "
                + "cp -R -- \(shellEscape(name)) \"$n\"")
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        // No action needed — see LocalFileTreePlugin.processChanged.
    }

    /// A commit or checkout in the remote shell changes git status without the explorer
    /// noticing, so re-read it when the terminal regains focus.
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        guard let session = context.remoteSession,
            let root = cachedRemoteRoots[Self.cacheKey(for: rootPath(for: context), session: session)]
        else { return }
        refreshGitStatus(root, session: session)
    }

    /// A listing the shell integration already fetched — apply it to every cached node
    /// showing that folder instead of asking the remote again.
    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        let listing = FileTreeNode.sorted(
            entries.map {
                FileTreeNode.Entry(
                    name: $0.name, path: RemoteFileTreeSource.childPath(path, $0.name), isDir: $0.isDirectory)
            })
        for root in cachedRemoteRoots.values {
            if let node = Self.findNode(path, in: root) { node.applyListing(listing) }
        }
    }

    /// The node for `path` below `node`, descending only through loaded folders.
    private static func findNode(_ path: String, in node: FileTreeNode) -> FileTreeNode? {
        guard node.isDirectory else { return nil }
        if node.path == path { return node }
        guard path.hasPrefix(node.path == "/" ? "/" : node.path + "/") else { return nil }
        for child in node.children ?? [] {
            if let found = findNode(path, in: child) { return found }
        }
        return nil
    }

    // MARK: - Git

    /// Re-read the remote `git status` for a root. One run per root at a time; a request
    /// arriving mid-run queues exactly one follow-up so the result is never stale.
    private func refreshGitStatus(_ root: FileTreeNode, session: RemoteSessionType) {
        guard AppSettings.shared.explorerGitDecorations else {
            root.gitStatus = nil
            return
        }
        let key = Self.cacheKey(for: root.path, session: session)
        guard !gitRefreshInFlight.contains(key) else {
            gitRefreshQueued.insert(key)
            return
        }
        gitRefreshInFlight.insert(key)
        let source = source(for: session)
        let path = root.path
        Task { [weak self, weak root] in
            let status = await source.gitStatus(rootPath: path)
            guard let self else { return }
            self.gitRefreshInFlight.remove(key)
            if let root, root.gitStatus != status { root.gitStatus = status }
            if self.gitRefreshQueued.remove(key) != nil, let root { self.refreshGitStatus(root, session: session) }
        }
    }

    // MARK: - Expanded State

    /// Save expanded state for the cached roots, so an eviction or a later revisit of
    /// any of those directories restores the same open folders.
    /// `except` skips the root that is staying put, whose live state is authoritative.
    private func snapshotExpandedState(except keptKey: String? = nil) {
        expandedState.snapshot(roots: cachedRemoteRoots, except: keptKey) { $0.expandedPaths() }
    }

    // MARK: - Internal

    nonisolated static func remoteRootPath(for context: TerminalContext) -> String {
        let remotePath = context.remoteCwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return remotePath.isEmpty ? "~" : remotePath
    }

    nonisolated static func displayPath(for context: TerminalContext) -> String {
        remoteRootPath(for: context)
    }

    /// Normalize session host for cache keying, using the SSH connection target (alias)
    /// so it matches the SSHControlManager socket key.
    private static func cacheHost(for session: RemoteSessionType) -> String {
        session.sshConnectionTarget
    }

    /// The `cachedRemoteRoots` key for a path — also the expanded-state key, so both
    /// caches agree on what "the same root" means.
    static func cacheKey(for path: String, session: RemoteSessionType) -> String {
        let resolved = RemoteExplorer.resolveTilde(path, session: session) ?? path
        return "\(cacheHost(for: session)):\(resolved)"
    }

    private func source(for session: RemoteSessionType) -> RemoteFileTreeSource {
        let key = "\(session.envType):\(session.sshConnectionTarget)"
        if let cached = sources[key] { return cached }
        let source = RemoteFileTreeSource(session: session)
        sources[key] = source
        return source
    }

    /// Test hook: the cached root node for a cache key, if one exists.
    func cachedRoot(forKey key: String) -> FileTreeNode? { cachedRemoteRoots[key] }

    /// Test hook: the cached root a context resolves to, so a test does not have to
    /// reproduce the key format.
    func cachedRoot(for context: TerminalContext) -> FileTreeNode? {
        guard let session = context.remoteSession else { return nil }
        return cachedRemoteRoots[Self.cacheKey(for: rootPath(for: context), session: session)]
    }

    /// Test hook: the open folders recorded for a context's root, if any.
    func savedExpandedPaths(for context: TerminalContext) -> Set<String>? {
        guard let session = context.remoteSession else { return nil }
        return expandedState.paths(for: Self.cacheKey(for: rootPath(for: context), session: session))
    }

    /// Returns the cached root for `path` on `session`, plus whether it was freshly
    /// created (a new root has already started loading, so callers must not reload).
    @discardableResult
    func getOrCreateRoot(for path: String, session: RemoteSessionType) -> (root: FileTreeNode, wasCreated: Bool) {
        let key = Self.cacheKey(for: path, session: session)
        if let cached = cachedRemoteRoots[key] {
            rootOrder.removeAll { $0 == key }
            rootOrder.append(key)
            return (cached, false)
        }
        let resolved = RemoteExplorer.resolveTilde(path, session: session) ?? path
        let name = (resolved as NSString).lastPathComponent
        let root = FileTreeNode(
            name: name.isEmpty ? "/" : name, path: resolved, isDirectory: true, source: source(for: session))
        root.isExpanded = true
        root.loadChildrenAsync()
        cachedRemoteRoots[key] = root
        rootOrder.append(key)
        if rootOrder.count > Self.maxCachedRoots {
            // Persist what we're about to drop so revisiting it restores its folders.
            snapshotExpandedState(except: key)
            if let oldest = rootOrder.first(where: { $0 != key }) { removeRoot(oldest) }
        }
        return (root, true)
    }

    private func removeRoot(_ key: String) {
        cachedRemoteRoots.removeValue(forKey: key)
        rootOrder.removeAll { $0 == key }
    }
}
