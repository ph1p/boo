import Combine
import SwiftUI

/// Built-in file tree plugin. Wraps existing FileTreeView/RemoteFileTreeView
/// into the unified plugin protocol.
@MainActor
final class FileTreePlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree",
        name: "Files",
        version: "1.0.0",
        icon: "folder",
        description: "File explorer for the focused terminal's directory",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "left", priority: 5, template: nil),
        settings: nil
    )

    /// Cached file tree roots keyed by path for instant switching.
    private var cachedRoots: [String: FileTreeNode] = [:]
    /// Cached remote tree roots keyed by "session:path".
    private var cachedRemoteRoots: [String: RemoteFileTreeNode] = [:]
    private var fileWatcher: FileSystemWatcher?
    private var bridgeSubscription: AnyCancellable?

    var hostActions: PluginHostActions? {
        didSet { subscribeToBridge() }
    }
    var onRequestCycleRerun: (() -> Void)?

    /// Bridge shortcut for internal use.
    private var bridge: TerminalBridge? { hostActions?.bridge }

    var prefersOuterScrollView: Bool { false }

    // MARK: - Section Title

    func sectionTitle(context: TerminalContext) -> String? {
        let dirName = (Self.displayPath(for: context) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        let dirName = (Self.displayPath(for: context) as NSString).lastPathComponent
        let label = context.isRemote ? "Files (remote)" : "Files"
        return StatusBarContent(
            text: dirName,
            icon: "folder",
            tint: nil,
            accessibilityLabel: "\(label): \(dirName)"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? {
        let ha = hostActions
        let actions = FileTreeActions(
            onFileClicked: { path in
                ha?.pastePathToActivePane?(path)
                actionHandler.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
            },
            onOpenInTab: { path in
                ha?.openDirectoryInNewTab?(path)
            },
            onOpenInPane: { path in
                ha?.openDirectoryInNewPane?(path)
            },
            onCopyPath: { path in
                actionHandler.handle(DSLAction(type: "copy", path: path, command: nil, text: nil))
            },
            onRevealInFinder: { path in
                actionHandler.handle(DSLAction(type: "reveal", path: path, command: nil, text: nil))
            },
            onRunCommand: { cmd in
                actionHandler.sendToTerminal?(cmd)
            },
            onNavigate: { path in
                ha?.sendRawToActivePane?("cd \(path)\r")
            }
        )

        if context.isRemote, let session = context.remoteSession {
            let root = getOrCreateRemoteRoot(for: Self.remoteRootPath(for: context), session: session)
            let host = session.displayName
            return AnyView(RemoteFileTreeView(root: root, actions: actions, host: host))
        }

        let root = getOrCreateRoot(for: context.cwd)
        return AnyView(FileTreeView(root: root, actions: actions))
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        guard !context.isRemote else { return }
        setupWatcher(for: newPath)
    }

    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        if session != nil {
            // Entering remote — stop local file watcher
            fileWatcher?.stop()
            fileWatcher = nil
        } else {
            // Back to local — restart watcher for current cwd
            setupWatcher(for: context.cwd)
        }
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        guard !context.isRemote else { return }
        setupWatcher(for: context.cwd)
    }

    // MARK: - Bridge Subscription

    /// Subscribe to bridge events so EXTERM_LS listings update the remote tree root
    /// in real-time (the injected shell hook fires on cd and each prompt).
    private func subscribeToBridge() {
        bridgeSubscription = hostActions?.bridge?.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case .remoteDirectoryListed(let path, let entries) = event else { return }
                self?.dispatchListing(path: path, entries: entries)
            }
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

    // MARK: - Internal

    nonisolated static func remoteRootPath(for context: TerminalContext) -> String {
        let remotePath = context.remoteCwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return remotePath.isEmpty ? "~" : remotePath
    }

    nonisolated static func displayPath(for context: TerminalContext) -> String {
        if context.isRemote {
            return remoteRootPath(for: context)
        }
        return context.cwd
    }

    private func getOrCreateRoot(for path: String) -> FileTreeNode {
        if let cached = cachedRoots[path] { return cached }
        let name = (path as NSString).lastPathComponent
        let root = FileTreeNode(name: name, path: path, isDirectory: true)
        root.loadChildren()
        root.isExpanded = true
        cachedRoots[path] = root
        setupWatcher(for: path)
        // Limit cache size
        if cachedRoots.count > 10 {
            let oldest = cachedRoots.keys.first { $0 != path }
            if let key = oldest { cachedRoots.removeValue(forKey: key) }
        }
        return root
    }

    private func setupWatcher(for path: String) {
        fileWatcher?.stop()
        fileWatcher = FileSystemWatcher(path: path) { [weak self] in
            self?.cachedRoots[path]?.refreshAll()
        }
        fileWatcher?.start()
    }

    /// Normalize session host for cache keying, using the SSH connection target (alias)
    /// so it matches the SSHControlManager socket key.
    private static func cacheHost(for session: RemoteSessionType) -> String {
        session.sshConnectionTarget
    }

    func getOrCreateRemoteRoot(for path: String, session: RemoteSessionType) -> RemoteFileTreeNode {
        // Resolve tilde to absolute path if possible (prevents cd '~/dir' quoting bug)
        let resolved = RemoteExplorer.resolveTilde(path, session: session) ?? path
        let host = Self.cacheHost(for: session)
        let key = "\(host):\(resolved)"
        if let cached = cachedRemoteRoots[key] { return cached }

        // Reuse any existing root for this host (regardless of path).
        // This prevents loader churn on `cd`: the old tree stays visible while
        // children reload for the new path, instead of creating a fresh root
        // that starts with nil children and shows a spinner.
        let hostPrefix = "\(host):"
        if let (existingKey, existingRoot) = cachedRemoteRoots.first(where: { $0.key.hasPrefix(hostPrefix) }) {
            cachedRemoteRoots.removeValue(forKey: existingKey)
            existingRoot.updatePath(resolved)
            cachedRemoteRoots[key] = existingRoot
            existingRoot.loadChildren()
            return existingRoot
        }

        let name = (resolved as NSString).lastPathComponent
        let root = RemoteFileTreeNode(name: name.isEmpty ? "/" : name, remotePath: resolved, isDirectory: true, session: session)
        root.bridge = bridge
        root.isExpanded = true
        cachedRemoteRoots[key] = root

        // If path has tilde and we couldn't resolve it yet, kick off async resolution.
        // Once the home dir is known, update the root's path so children get absolute paths.
        if resolved.hasPrefix("~") {
            RemoteExplorer.resolveRemoteHome(session: session) { [weak root, weak self] home in
                guard let root = root, let self = self, let home = home else {
                    root?.loadChildren()
                    return
                }
                let absolutePath: String
                if resolved == "~" {
                    absolutePath = home
                } else {
                    // ~/foo → /home/user/foo
                    absolutePath = home + String(resolved.dropFirst(1))
                }
                let newKey = "\(host):\(absolutePath)"
                self.cachedRemoteRoots.removeValue(forKey: key)
                root.updatePath(absolutePath)
                self.cachedRemoteRoots[newKey] = root
                root.loadChildren()
            }
        } else {
            root.loadChildren()
        }

        // Limit cache
        if cachedRemoteRoots.count > 5 {
            let oldest = cachedRemoteRoots.keys.first { $0 != key }
            if let k = oldest { cachedRemoteRoots.removeValue(forKey: k) }
        }
        return root
    }
}
