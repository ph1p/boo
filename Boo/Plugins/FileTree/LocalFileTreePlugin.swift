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
                defaultValue: AnyCodableValue(false), options: nil),
            PluginManifest.SettingManifest(
                key: "showIcons", type: .bool, label: "Show file icons",
                defaultValue: AnyCodableValue(true), options: nil),
            PluginManifest.SettingManifest(
                key: "showPath", type: .bool, label: "Show current path",
                defaultValue: AnyCodableValue(true), options: nil),
            PluginManifest.SettingManifest(
                key: "showProcess", type: .bool, label: "Show running process",
                defaultValue: AnyCodableValue(true), options: nil),
            PluginManifest.SettingManifest(
                key: "editorFilePatterns", type: .string,
                label: "Open in editor (file patterns)",
                defaultValue: AnyCodableValue(ContentType.builtInEditorFilePatterns),
                options: "editorFilePatterns"),
            PluginManifest.SettingManifest(
                key: "markdownOpenMode", type: .string,
                label: "Open markdown files as",
                defaultValue: AnyCodableValue("preview"),
                options: "markdownOpenMode"),
            PluginManifest.SettingManifest(
                key: "imageOpenMode", type: .string,
                label: "Open images as",
                defaultValue: AnyCodableValue("imageViewer"),
                options: "imageOpenMode"),
            PluginManifest.SettingManifest(
                key: "textOpenMode", type: .string,
                label: "Open text files as",
                defaultValue: AnyCodableValue("editor"),
                options: "textOpenMode"),
            PluginManifest.SettingManifest(
                key: "htmlOpenInBrowser", type: .bool,
                label: "Open HTML files in browser",
                defaultValue: AnyCodableValue(false), options: nil),
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

    // MARK: - Sidebar Tab (two sections: file tree + folder info)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }
        guard let treeView = makeDetailView(context: context) else { return nil }
        let title = sectionTitle(context: context) ?? manifest.name
        let cwd = context.terminal.cwd

        let treeSection = SidebarSection(
            id: manifest.id,
            name: title,
            icon: manifest.icon,
            content: treeView,
            prefersOuterScrollView: true,
            generation: 0
        )
        let infoSection = SidebarSection(
            id: "\(manifest.id).info",
            name: "Folder Info",
            icon: "info.circle",
            content: AnyView(FolderInfoView(path: cwd, fontScale: context.fontScale, theme: context.theme)),
            prefersOuterScrollView: true,
            generation: 0
        )
        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: [treeSection, infoSection]
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        let act = self.actions
        let isAI = ProcessIcon.category(for: context.terminal.processName) == "ai"
        let treeActions = FileTreeActions(
            onFileClicked: { path in
                let ext = (path as NSString).pathExtension.lowercased()
                let filename = ((path as NSString).lastPathComponent).lowercased()
                let isImage = ContentType.imageExtensions.contains(ext)
                let isMarkdown = ContentType.markdownExtensions.contains(ext)
                let isHTML = ContentType.htmlExtensions.contains(ext)
                let isEditorFile = ContentType.isEditorFilePattern(filename: filename)

                let htmlOpenInBrowser = AppSettings.shared.pluginBool(
                    "file-tree-local", "htmlOpenInBrowser", default: false)
                if isHTML && htmlOpenInBrowser {
                    act?.openTab?(.browser(url: URL(fileURLWithPath: path)))
                } else if isImage {
                    let imageModeRaw = AppSettings.shared.pluginString(
                        "file-tree-local", "imageOpenMode", default: "imageViewer")
                    let imageMode = ImageOpenMode(rawValue: imageModeRaw) ?? .imageViewer
                    switch imageMode {
                    case .kitty:
                        act?.displayImageInTerminal?(path, false)
                    case .external:
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    case .multiContent, .imageViewer:
                        act?.openTab?(.file(path: path))
                    }
                } else if isMarkdown {
                    act?.openTab?(.file(path: path))
                } else if isEditorFile {
                    let textModeRaw = AppSettings.shared.pluginString(
                        "file-tree-local", "textOpenMode", default: "editor")
                    let textMode = TextOpenMode(rawValue: textModeRaw) ?? .editor
                    switch textMode {
                    case .terminalEditor:
                        let parentDir = (path as NSString).deletingLastPathComponent
                        act?.openDirectoryInNewTab?(parentDir)
                        let configured = AppSettings.shared.fileEditorCommand.trimmingCharacters(
                            in: .whitespaces
                        )
                        let editorCmd = configured.isEmpty
                            ? (ProcessInfo.processInfo.environment["EDITOR"] ?? "vi")
                            : configured
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            act?.sendToTerminal?("\(editorCmd) \(shellEscape(path))\r")
                        }
                    case .external:
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    case .editor, .multiContent:
                        act?.openTab?(.file(path: path))
                    }
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            },
            onPastePath: { path in
                act?.pastePath(path)
            },
            onOpenInTab: { path in
                act?.openDirectoryInNewTab?(path)
            },
            onOpenInPane: { path in
                act?.openDirectoryInNewPane?(path)
            },
            onOpenFileInTab: { path in
                act?.openTab?(.file(path: path))
            },
            onOpenFileInPane: { path in
                act?.openFileInNewPane?(path)
            },
            onOpenFileInBrowser: { path in
                act?.openTab?(.browser(url: URL(fileURLWithPath: path)))
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
                        for (rootPath, root) in self.cachedRoots where path.hasPrefix(rootPath) {
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

        // On context switch, always reload the root's children — the root may be a
        // cached node whose children are nil (e.g. after eviction) or stale, and
        // SwiftUI's onAppear doesn't fire when rootView is replaced in-place via
        // NSHostingView.rootView, so we must trigger the load here.
        if !isSameTerminalAndCwd {
            root.loadChildren()
        }

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
            FolderInfoCache.shared.invalidate(path)
        }
        fileWatcher?.start()
    }
}
