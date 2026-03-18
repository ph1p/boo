import Combine
import SwiftUI

/// Built-in local file tree plugin. Shows the file explorer for local directories.
@MainActor
final class LocalFileTreePlugin: ExtermPluginProtocol {
    let manifest = PluginManifest(
        id: "file-tree-local",
        name: "Files",
        version: "1.0.0",
        icon: "folder",
        description: "File explorer for local directories",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "left", priority: 5, template: nil),
        settings: nil
    )

    /// Cached file tree roots keyed by path for instant switching.
    private var cachedRoots: [String: FileTreeNode] = [:]
    private var fileWatcher: FileSystemWatcher?

    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { false }

    // MARK: - Section Title

    func sectionTitle(context: TerminalContext) -> String? {
        let dirName = (context.cwd as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        let dirName = (context.cwd as NSString).lastPathComponent
        return StatusBarContent(
            text: dirName,
            icon: "folder",
            tint: nil,
            accessibilityLabel: "Files: \(dirName)"
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

        let root = getOrCreateRoot(for: context.cwd)
        return AnyView(FileTreeView(root: root, actions: actions))
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        setupWatcher(for: newPath)
    }

    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        if session != nil {
            fileWatcher?.stop()
            fileWatcher = nil
        } else {
            setupWatcher(for: context.cwd)
        }
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        setupWatcher(for: context.cwd)
    }

    // MARK: - Internal

    private func getOrCreateRoot(for path: String) -> FileTreeNode {
        if let cached = cachedRoots[path] { return cached }
        let name = (path as NSString).lastPathComponent
        let root = FileTreeNode(name: name, path: path, isDirectory: true)
        root.loadChildren()
        root.isExpanded = true
        cachedRoots[path] = root
        setupWatcher(for: path)
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
}
