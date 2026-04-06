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

    var subscribedEvents: Set<PluginEvent> {
        [.cwdChanged, .remoteSessionChanged, .focusChanged, .processChanged, .terminalClosed]
    }

    func terminalClosed(terminalID: UUID) {
        expandedState.removeValue(forKey: terminalID)
        terminalCwd.removeValue(forKey: terminalID)
    }

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
                act?.sendToTerminal?("cd \(shellEscape(path))\r")
            },
            onMoveToTrash: { [weak self] path in
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.recycle([url]) { _, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Refresh any cached root that contains the trashed path.
                        for (rootPath, root) in self.cachedRoots where path.hasPrefix(rootPath) {
                            root.refreshAll()
                        }
                    }
                }
            },
            onRename: { oldPath, newName in
                guard !newName.contains("/"), !newName.contains("..") else {
                    NSSound.beep()
                    return
                }
                let parentDir = (oldPath as NSString).deletingLastPathComponent
                let newPath = (parentDir as NSString).appendingPathComponent(newName)
                guard oldPath != newPath else { return }
                do {
                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                } catch {
                    NSSound.beep()
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
                    // moveItem throws if dest exists — no need for pre-check
                    NSSound.beep()
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
                    NSSound.beep()
                }
            },
            onReferenceInAI: { path in
                act?.sendToTerminal?("@\(path) ")
            },
            isAIAgentRunning: isAI
        )

        let tid = context.terminal.terminalID
        let cwd = context.terminal.cwd
        let isSameTerminalAndCwd = (tid == lastTerminalID && terminalCwd[tid] == cwd)

        if !isSameTerminalAndCwd {
            saveExpandedState()
        }
        let root = getOrCreateRoot(for: cwd)

        // Only restore on terminal/CWD switch — skipping on same-context re-renders
        // prevents save→restore from collapsing folders the user just opened.
        if !isSameTerminalAndCwd, let saved = expandedState[tid] {
            root.restoreExpanded(saved)
        }
        lastTerminalID = tid
        terminalCwd[tid] = cwd

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

    func processChanged(name: String, context: TerminalContext) {
        // No action needed — makeDetailView reads the current processName
        // from the context on every plugin cycle, so isAIAgentRunning is
        // always up to date.  Do NOT call onRequestCycleRerun here:
        // processChanged is invoked *during* a plugin cycle, so triggering
        // another cycle would cause infinite recursion.
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
            // Evict all entries except the current path to bound cache growth
            cachedRoots = cachedRoots.filter { $0.key == path }
        }
        return root
    }

    private func setupWatcher(for path: String) {
        fileWatcher?.stop()
        fileWatcher = FileSystemWatcher(path: path) { [weak self] in
            // Refresh all cached roots that are under (or equal to) the
            // watched path, so subdirectory changes are picked up too.
            guard let self else { return }
            for (rootPath, root) in self.cachedRoots where path.hasPrefix(rootPath) || rootPath.hasPrefix(path) {
                root.refreshAll()
            }
        }
        fileWatcher?.start()
    }
}
