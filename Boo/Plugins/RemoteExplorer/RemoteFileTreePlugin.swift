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

    /// Expanded directory paths per terminal (tab) ID.
    private var expandedState: [UUID: Set<String>] = [:]
    /// Cache key per terminal so we can find the right root on save.
    private var terminalCacheKey: [UUID: String] = [:]
    /// The last terminal ID we rendered for.
    private var lastTerminalID: UUID?

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { true }

    var subscribedEvents: Set<PluginEvent> { [.processChanged, .remoteDirectoryListed] }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        let dirName = (Self.remoteRootPath(for: context.terminal) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard let session = context.terminal.remoteSession else { return nil }

        let act = self.actions
        let isAI = ProcessIcon.category(for: context.terminal.processName) == "ai"
        let treeActions = FileTreeActions(
            onFileClicked: { path in
                act?.pastePath(path)
            },
            onOpenInTab: { path in
                act?.openDirectoryInNewTab?(path)
            },
            onOpenInPane: { path in
                act?.openDirectoryInNewPane?(path)
            },
            onCopyPath: { path in
                act?.handle(DSLAction(type: "copy", path: path, command: nil, text: nil))
            },
            onRevealInFinder: { path in
                act?.handle(DSLAction(type: "reveal", path: path, command: nil, text: nil))
            },
            onRunCommand: { cmd in
                act?.sendToTerminal?(cmd)
            },
            onNavigate: { path in
                act?.sendToTerminal?("cd \(RemoteExplorer.shellEscPath(path))\r")
            },
            onReferenceInAI: { path in
                act?.sendToTerminal?("@\(path) ")
            },
            isAIAgentRunning: isAI
        )

        let tid = context.terminal.terminalID
        saveExpandedState()
        let rootPath = Self.remoteRootPath(for: context.terminal)
        let root = getOrCreateRemoteRoot(for: rootPath, session: session)
        let host = session.displayName

        // Restore expanded folders for this terminal
        if let saved = expandedState[tid] {
            root.restoreExpanded(saved)
        }
        let cacheHost = Self.cacheHost(for: session)
        let resolved = RemoteExplorer.resolveTilde(rootPath, session: session) ?? rootPath
        terminalCacheKey[tid] = "\(cacheHost):\(resolved)"
        lastTerminalID = tid

        return AnyView(RemoteFileTreeView(root: root, actions: treeActions, host: host))
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

    /// Save the expanded folder state for the last active terminal.
    private func saveExpandedState() {
        guard let prevID = lastTerminalID,
            let key = terminalCacheKey[prevID],
            let root = cachedRemoteRoots[key]
        else { return }
        expandedState[prevID] = root.expandedPaths()
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
        } else {
            root.loadChildren()
        }

        if cachedRemoteRoots.count > 5 {
            let oldest = cachedRemoteRoots.keys.first { $0 != key }
            if let k = oldest { cachedRemoteRoots.removeValue(forKey: k) }
        }
        return root
    }
}
