import Combine
import SwiftUI

/// Built-in remote file tree plugin. Shows the file explorer for SSH/Docker sessions.
@MainActor
final class RemoteFileTreePlugin: BooPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree-remote",
        name: "Files (Remote)",
        version: "1.0.0",
        icon: "folder.badge.gearshape",
        description: "File explorer for remote sessions",
        when: "env.ssh",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    /// Cached remote tree roots keyed by "session:path".
    private var cachedRemoteRoots: [String: RemoteFileTreeNode] = [:]

    /// Open folders per `"host:path"` cache key — see `ExpandedStateStore` for why the
    /// key is the root and not the terminal.
    private var expandedState = ExpandedStateStore()
    /// Row actions, built once and reused — only `isAIAgentRunning` varies per cycle.
    private var treeActions: FileTreeActions?
    /// Cache key per terminal, so a re-render in the same context is recognisable.
    private var terminalCacheKey: [UUID: String] = [:]
    /// The last terminal ID we rendered for.
    private var lastTerminalID: UUID?

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { true }

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .remoteDirectoryListed, .terminalClosed] }

    /// Drop the per-terminal cwd mapping when a terminal closes so the dict doesn't grow
    /// one entry per terminal ever opened. Mirrors LocalFileTreePlugin — the expanded
    /// state itself is keyed by root and outlives the terminal on purpose.
    func terminalClosed(terminalID: UUID) {
        terminalCacheKey.removeValue(forKey: terminalID)
        if lastTerminalID == terminalID { lastTerminalID = nil }
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        let dirName = (Self.remoteRootPath(for: context.terminal) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    /// `RemoteFileTreeView` observes its root node, so a directory listing arriving does not
    /// need a rootView swap — and a swap would collapse the tree and reset its scroll offset.
    /// Only the identity of the node itself (host + resolved root path) and the AI flag baked
    /// into the row actions change what the section renders. Mirrors `LocalFileTreePlugin`.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        guard let session = context.terminal.remoteSession else { return 0 }
        let key = Self.cacheKey(for: Self.remoteRootPath(for: context.terminal), session: session)
        let isAIAgent = FileTreeActions.isAIAgentContext(context)
        return SidebarSection.generation(for: [key, isAIAgent ? "ai" : "plain"])
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard let session = context.terminal.remoteSession else { return nil }

        // Built once and reused — only `isAIAgentRunning` varies per cycle.
        if treeActions == nil { treeActions = buildTreeActions() }
        treeActions?.isAIAgentRunning = FileTreeActions.isAIAgentContext(context)
        guard let treeActions else { return nil }

        let tid = context.terminal.terminalID
        let rootPath = Self.remoteRootPath(for: context.terminal)
        let cacheKey = Self.cacheKey(for: rootPath, session: session)
        let isSameContext = (tid == lastTerminalID && terminalCacheKey[tid] == cacheKey)

        if !isSameContext {
            // The root we're leaving keeps its open folders under its own key.
            snapshotExpandedState(except: cacheKey)
        }
        let root = getOrCreateRemoteRoot(for: rootPath, session: session)
        let host = session.displayName

        // Only restore on terminal/path switch — re-running it on a same-context cycle
        // (a foreground-process change, say) would collapse a folder the user just opened.
        if !isSameContext, let saved = expandedState.paths(for: cacheKey) {
            root.restoreExpanded(saved)
        }
        terminalCacheKey[tid] = cacheKey
        lastTerminalID = tid

        return AnyView(RemoteFileTreeView(root: root, actions: treeActions, host: host))
    }

    private func buildTreeActions() -> FileTreeActions {
        // Resolved on each invocation rather than captured: `PluginRegistry.actions` is
        // reassigned after registration, and these closures outlive that assignment.
        let act: @MainActor () -> PluginActions? = { [weak self] in self?.actions }
        return FileTreeActions(
            onFileClicked: { path in
                act()?.pastePath(path)
            },
            onOpenInTab: { path in
                act()?.openDirectoryInNewTab?(path)
            },
            onOpenInPane: { path in
                act()?.openDirectoryInNewPane?(path)
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
                act()?.sendToTerminal?("cd \(RemoteExplorer.shellEscPath(path))\r")
            },
            onReferenceInAI: { path in
                act()?.sendToTerminal?("@\(path) ")
            },
            isAIAgentRunning: false
        )
    }

    // MARK: - Lifecycle

    func processChanged(name: String, context: TerminalContext) {
        // No action needed — see LocalFileTreePlugin.processChanged.
    }

    // MARK: - Remote Directory Listing (replaces bridge subscription)

    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        dispatchListing(path: path, entries: entries)
    }

    private func dispatchListing(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        for root in cachedRemoteRoots.values {
            deliverListing(to: root, path: path, entries: entries)
        }
    }

    private func deliverListing(to node: RemoteFileTreeNode, path: String, entries: [RemoteExplorer.RemoteEntry]) {
        if node.remotePath == path {
            node.applyEntries(entries)
            return
        }
        guard let children = node.children else { return }
        for child in children where child.isDirectory {
            deliverListing(to: child, path: path, entries: entries)
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
    private static func cacheKey(for path: String, session: RemoteSessionType) -> String {
        let resolved = RemoteExplorer.resolveTilde(path, session: session) ?? path
        return "\(cacheHost(for: session)):\(resolved)"
    }

    /// Test hook: the cached root node for a cache key, if one exists.
    func cachedRoot(forKey key: String) -> RemoteFileTreeNode? { cachedRemoteRoots[key] }

    /// Test hook: the cached root a context resolves to, so a test does not have to
    /// reproduce the key format.
    func cachedRoot(for context: TerminalContext) -> RemoteFileTreeNode? {
        guard let session = context.remoteSession else { return nil }
        return cachedRemoteRoots[Self.cacheKey(for: Self.remoteRootPath(for: context), session: session)]
    }

    /// Test hook: the open folders recorded for a context's root, if any.
    func savedExpandedPaths(for context: TerminalContext) -> Set<String>? {
        guard let session = context.remoteSession else { return nil }
        return expandedState.paths(
            for: Self.cacheKey(for: Self.remoteRootPath(for: context), session: session))
    }

    func getOrCreateRemoteRoot(for path: String, session: RemoteSessionType) -> RemoteFileTreeNode {
        let resolved = RemoteExplorer.resolveTilde(path, session: session) ?? path
        let host = Self.cacheHost(for: session)
        let key = "\(host):\(resolved)"
        remoteLog(
            "[RemoteFileTree] getOrCreateRemoteRoot: path=\(path) resolved=\(resolved) key=\(key) session=\(session)")
        if let cached = cachedRemoteRoots[key] {
            remoteLog("[RemoteFileTree] cache hit for key=\(key)")
            return cached
        }

        let hostPrefix = "\(host):"
        if let (existingKey, existingRoot) = cachedRemoteRoots.first(where: { $0.key.hasPrefix(hostPrefix) }) {
            // This host's single root is being re-pointed at `resolved` — record what was
            // open at the old path first, so cd-ing back there restores those folders.
            snapshotExpandedState(except: key)
            cachedRemoteRoots.removeValue(forKey: existingKey)
            existingRoot.updatePath(resolved)
            cachedRemoteRoots[key] = existingRoot
            existingRoot.loadChildren()
            return existingRoot
        }

        let name = (resolved as NSString).lastPathComponent
        let root = RemoteFileTreeNode(
            name: name.isEmpty ? "/" : name, remotePath: resolved, isDirectory: true, session: session)
        root.onRequestListing = { [weak self] path in
            self?.onRequestCycleRerun?()
        }
        root.isExpanded = true
        cachedRemoteRoots[key] = root

        if resolved.hasPrefix("~") {
            RemoteExplorer.resolveRemoteHome(session: session) { [weak root, weak self] home in
                Task { @MainActor [weak root, weak self] in
                    guard let root = root, let self = self, let home = home else {
                        root?.loadChildren()
                        return
                    }
                    let absolutePath: String
                    if resolved == "~" {
                        absolutePath = home
                    } else {
                        absolutePath = home + String(resolved.dropFirst(1))
                    }
                    let newKey = "\(host):\(absolutePath)"
                    self.cachedRemoteRoots.removeValue(forKey: key)
                    root.updatePath(absolutePath)
                    self.cachedRemoteRoots[newKey] = root
                    root.loadChildren()
                }
            }
        } else {
            root.loadChildren()
        }

        if cachedRemoteRoots.count > 5 {
            // Persist what we're about to drop so revisiting that host restores its folders.
            snapshotExpandedState(except: key)
            let oldest = cachedRemoteRoots.keys.first { $0 != key }
            if let k = oldest { cachedRemoteRoots.removeValue(forKey: k) }
        }
        return root
    }
}
