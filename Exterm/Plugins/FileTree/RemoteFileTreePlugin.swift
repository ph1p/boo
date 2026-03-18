import Combine
import SwiftUI

/// Built-in remote file tree plugin. Shows the file explorer for SSH/Docker sessions.
@MainActor
final class RemoteFileTreePlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree-remote",
        name: "Files (Remote)",
        version: "1.0.0",
        icon: "folder.badge.gearshape",
        description: "File explorer for remote sessions",
        when: "remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: false),
        statusBar: nil,
        settings: nil
    )

    /// Cached remote tree roots keyed by "session:path".
    private var cachedRemoteRoots: [String: RemoteFileTreeNode] = [:]
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
        let dirName = (Self.remoteRootPath(for: context) as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        let dirName = (Self.remoteRootPath(for: context) as NSString).lastPathComponent
        return StatusBarContent(
            text: dirName,
            icon: "folder.badge.gearshape",
            tint: nil,
            accessibilityLabel: "Files (remote): \(dirName)"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? {
        guard let session = context.remoteSession else { return nil }

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

        let root = getOrCreateRemoteRoot(for: Self.remoteRootPath(for: context), session: session)
        let host = session.displayName
        return AnyView(RemoteFileTreeView(root: root, actions: actions, host: host))
    }

    // MARK: - Bridge Subscription

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
        if let cached = cachedRemoteRoots[key] { return cached }

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
