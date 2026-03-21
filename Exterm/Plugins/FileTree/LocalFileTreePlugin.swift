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
        settings: [
            PluginManifest.SettingManifest(
                key: "showHiddenFiles", type: .bool, label: "Show hidden files", defaultValue: AnyCodableValue(false),
                options: nil),
            PluginManifest.SettingManifest(
                key: "showIcons", type: .bool, label: "Show file icons", defaultValue: AnyCodableValue(true),
                options: nil),
            PluginManifest.SettingManifest(
                key: "fontSize", type: .double, label: "Font size", defaultValue: AnyCodableValue(12.0), options: nil),
            PluginManifest.SettingManifest(
                key: "fontName", type: .string, label: "Font", defaultValue: AnyCodableValue(""),
                options: "fontPicker:system"),
            PluginManifest.SettingManifest(
                key: "showPath", type: .bool, label: "Show current path", defaultValue: AnyCodableValue(true),
                options: nil),
            PluginManifest.SettingManifest(
                key: "showProcess", type: .bool, label: "Show running process", defaultValue: AnyCodableValue(true),
                options: nil)
        ]
    )

    /// Cached file tree roots keyed by path for instant switching.
    private var cachedRoots: [String: FileTreeNode] = [:]
    private var fileWatcher: FileSystemWatcher?

    /// Expanded directory paths per terminal (tab) ID.
    private var expandedState: [UUID: Set<String>] = [:]
    /// CWD per terminal so we can find the right root on save.
    private var terminalCwd: [UUID: String] = [:]
    /// The last terminal ID we rendered for, so we can save state on switch.
    private var lastTerminalID: UUID?

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    var prefersOuterScrollView: Bool { true }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        let dirName = (context.terminal.cwd as NSString).lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        let dirName = (context.terminal.cwd as NSString).lastPathComponent
        return StatusBarContent(
            text: dirName,
            icon: "folder",
            tint: nil,
            accessibilityLabel: "Files: \(dirName)"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        let act = self.actions
        let treeActions = FileTreeActions(
            onFileClicked: { path in
                act?.pastePath(path)
                act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
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
                act?.sendToTerminal?("cd \(shellEscape(path))\r")
            },
            onMoveToTrash: { [weak self] path in
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.recycle([url]) { _, _ in
                    DispatchQueue.main.async {
                        // Refresh the parent directory after trashing
                        let parent = (path as NSString).deletingLastPathComponent
                        self?.cachedRoots[parent]?.refreshAll()
                    }
                }
            }
        )

        let tid = context.terminal.terminalID
        saveExpandedState()
        let root = getOrCreateRoot(for: context.terminal.cwd)

        // Restore expanded folders for this terminal
        if let saved = expandedState[tid] {
            root.restoreExpanded(saved)
        }
        lastTerminalID = tid
        terminalCwd[tid] = context.terminal.cwd

        return AnyView(FileTreeView(root: root, actions: treeActions))
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

    /// Save the expanded folder state for the last active terminal.
    private func saveExpandedState() {
        guard let prevID = lastTerminalID,
              let cwd = terminalCwd[prevID],
              let root = cachedRoots[cwd]
        else { return }
        expandedState[prevID] = root.expandedPaths()
    }

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
