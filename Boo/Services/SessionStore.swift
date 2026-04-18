import Cocoa
import Foundation

// MARK: - Codable session snapshot types

struct SessionTab: Codable {
    let title: String
    let workingDirectory: String
    let contentState: ContentState?
    // Remote sessions are intentionally omitted — only local state is persisted.
    // Sidebar state — optional so old session.json files decode without error.
    let expandedPluginIDs: [String]?
    let userCollapsedSectionIDs: [String]?
    let sidebarSectionHeights: [String: Double]?
    let sidebarScrollOffsets: [String: [Double]]?
    let sidebarSectionOrder: [String: [String]]?
    let selectedPluginTabID: String?

    init(
        title: String,
        workingDirectory: String,
        contentState: ContentState? = nil,
        expandedPluginIDs: [String]? = nil,
        userCollapsedSectionIDs: [String]? = nil,
        sidebarSectionHeights: [String: Double]? = nil,
        sidebarScrollOffsets: [String: [Double]]? = nil,
        sidebarSectionOrder: [String: [String]]? = nil,
        selectedPluginTabID: String? = nil
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.contentState = contentState
        self.expandedPluginIDs = expandedPluginIDs
        self.userCollapsedSectionIDs = userCollapsedSectionIDs
        self.sidebarSectionHeights = sidebarSectionHeights
        self.sidebarScrollOffsets = sidebarScrollOffsets
        self.sidebarSectionOrder = sidebarSectionOrder
        self.selectedPluginTabID = selectedPluginTabID
    }
}

struct SessionPane: Codable {
    let id: UUID
    let tabs: [SessionTab]
    let activeTabIndex: Int
}

struct SessionWorkspace: Codable {
    let id: UUID
    let folderPath: String
    let customName: String?
    let color: String  // WorkspaceColor.rawValue
    let customColorRed: CGFloat?
    let customColorGreen: CGFloat?
    let customColorBlue: CGFloat?
    let isPinned: Bool
    let splitTree: SplitTree
    let panes: [SessionPane]
    let activePaneID: UUID
    // Per-workspace sidebar state — optional for backwards compatibility
    let sidebarIsVisible: Bool?
    let sidebarWidth: Double?
}

struct SessionSnapshot: Codable {
    let activeWorkspaceIndex: Int
    let workspaces: [SessionWorkspace]
}

// MARK: - SessionStore

enum SessionStore {
    private nonisolated(unsafe) static var _testFilePath: String? = nil

    /// Override the storage path. Pass `nil` to revert to the default. Tests only.
    static func overrideFilePathForTesting(_ path: String?) {
        _testFilePath = path
    }

    private static var sessionFile: String {
        _testFilePath ?? BooPaths.configDir.appendingPathComponent("session.json")
    }

    static func save(appState: AppState) {
        let workspaces = appState.workspaces.map { ws -> SessionWorkspace in
            ws.normalizePaneState()
            let panes = ws.panes.values.map { pane -> SessionPane in
                let tabs = pane.tabs.map { tab in
                    SessionTab(
                        title: tab.title,
                        workingDirectory: tab.workingDirectory,
                        contentState: tab.contentType.isPersistable ? tab.state.contentState : nil,
                        expandedPluginIDs: Array(tab.state.expandedPluginIDs),
                        userCollapsedSectionIDs: Array(tab.state.userCollapsedSectionIDs),
                        sidebarSectionHeights: tab.state.sidebarSectionHeights.mapValues {
                            Double($0)
                        },
                        sidebarScrollOffsets: tab.state.sidebarScrollOffsets.mapValues {
                            [$0.x, $0.y]
                        },
                        sidebarSectionOrder: tab.state.sidebarSectionOrder,
                        selectedPluginTabID: tab.state.selectedPluginTabID
                    )
                }
                return SessionPane(
                    id: pane.id,
                    tabs: tabs,
                    activeTabIndex: pane.activeTabIndex
                )
            }

            var red: CGFloat? = nil
            var green: CGFloat? = nil
            var blue: CGFloat? = nil
            if let cc = ws.customColor {
                let rgb = cc.usingColorSpace(.sRGB) ?? cc
                red = rgb.redComponent
                green = rgb.greenComponent
                blue = rgb.blueComponent
            }

            return SessionWorkspace(
                id: ws.id,
                folderPath: ws.folderPath,
                customName: ws.customName,
                color: ws.color.rawValue,
                customColorRed: red,
                customColorGreen: green,
                customColorBlue: blue,
                isPinned: ws.isPinned,
                splitTree: ws.splitTree,
                panes: panes,
                activePaneID: ws.activePaneID,
                sidebarIsVisible: ws.sidebarState.isVisible,
                sidebarWidth: ws.sidebarState.width.map { Double($0) }
            )
        }

        let snapshot = SessionSnapshot(
            activeWorkspaceIndex: appState.activeWorkspaceIndex,
            workspaces: workspaces
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: sessionFile), options: .atomic)
        } catch {
            booLog(.error, .app, "Failed to save session: \(error)")
        }
    }

    /// Returns nil when no session file exists or the file cannot be decoded.
    static func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: sessionFile) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            debugLog("[SessionStore] Failed to load session: \(error)")
            return nil
        }
    }

    /// Reconstruct Workspace objects from a snapshot, skipping any workspaces
    /// whose folderPath no longer exists on disk.
    static func workspaces(from snapshot: SessionSnapshot) -> [Workspace] {
        let restored: [Workspace] = snapshot.workspaces.compactMap { sw -> Workspace? in
            // Only restore workspaces whose root folder still exists.
            guard FileManager.default.fileExists(atPath: sw.folderPath) else {
                debugLog("[SessionStore] Skipping workspace at \(sw.folderPath) — path not found")
                return nil
            }

            let ws = Workspace(
                folderPath: sw.folderPath,
                id: sw.id,
                splitTree: sw.splitTree,
                activePaneID: sw.activePaneID
            )
            ws.customName = sw.customName
            ws.color = WorkspaceColor(rawValue: sw.color) ?? .none
            ws.isPinned = sw.isPinned
            if let r = sw.customColorRed, let g = sw.customColorGreen, let b = sw.customColorBlue {
                ws.customColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            let defaultSidebarState = Workspace.defaultSidebarState()
            ws.sidebarState = SidebarWorkspaceState(
                isVisible: sw.sidebarIsVisible ?? defaultSidebarState.isVisible,
                width: sw.sidebarWidth.map { CGFloat($0) } ?? defaultSidebarState.width
            )

            // Build a lookup so we can match panes to split-tree leaf IDs
            let paneByID = Dictionary(uniqueKeysWithValues: sw.panes.map { ($0.id, $0) })
            let leafIDs = sw.splitTree.leafIDs

            for leafID in leafIDs {
                let pane = Pane(id: leafID)
                if let sp = paneByID[leafID], !sp.tabs.isEmpty {
                    for tab in sp.tabs {
                        let restoredState =
                            if let contentState = tab.contentState,
                                contentState.contentType.isPersistable,
                                isContentStateRestorable(contentState)
                            {
                                contentState
                            } else {
                                ContentState.terminal(
                                    TerminalContentState(
                                        title: tab.title,
                                        workingDirectory: tab.workingDirectory
                                    )
                                )
                            }
                        let idx = pane.addTab(
                            contentType: restoredState.contentType,
                            workingDirectory: restoredWorkingDirectory(
                                for: restoredState,
                                fallback: tab.workingDirectory,
                                workspacePath: sw.folderPath
                            ),
                            title: restoredState.title
                        )
                        pane.updateContentState(at: idx, restoredState)
                        pane.updatePluginState(
                            at: idx,
                            expanded: Set(tab.expandedPluginIDs ?? []),
                            userCollapsed: Set(tab.userCollapsedSectionIDs ?? []),
                            sidebarSectionHeights: (tab.sidebarSectionHeights ?? [:]).mapValues {
                                CGFloat($0)
                            },
                            sidebarScrollOffsets: (tab.sidebarScrollOffsets ?? [:])
                                .compactMapValues { arr in
                                    guard arr.count == 2 else { return nil }
                                    return CGPoint(x: arr[0], y: arr[1])
                                },
                            sidebarSectionOrder: tab.sidebarSectionOrder ?? [:],
                            selectedPluginTabID: tab.selectedPluginTabID
                        )
                    }
                    let safeIndex = min(max(sp.activeTabIndex, 0), sp.tabs.count - 1)
                    pane.setActiveTab(safeIndex)
                } else {
                    // Fallback: single tab at the workspace root
                    pane.addTab(workingDirectory: sw.folderPath)
                }
                ws.restorePane(pane)
            }

            ws.normalizePaneState()

            return ws
        }

        AppState.ensureUniquePaneIDsAcrossWorkspaces(restored)
        return restored
    }

    private static func isContentStateRestorable(_ state: ContentState) -> Bool {
        switch state {
        case .editor(let s):
            guard let path = s.filePath, !path.isEmpty else { return true }
            return FileManager.default.fileExists(atPath: path)
        case .imageViewer(let s):
            return s.filePath.isEmpty || FileManager.default.fileExists(atPath: s.filePath)
        case .markdownPreview(let s):
            return s.filePath.isEmpty || FileManager.default.fileExists(atPath: s.filePath)
        default:
            return true
        }
    }

    private static func restoredWorkingDirectory(
        for contentState: ContentState,
        fallback: String,
        workspacePath: String
    ) -> String {
        switch contentState {
        case .terminal(let terminalState):
            return terminalState.workingDirectory
        case .browser(let browserState):
            if browserState.url.isFileURL {
                return browserState.url.deletingLastPathComponent().path
            }
        case .editor(let editorState):
            if let filePath = editorState.filePath, !filePath.isEmpty {
                return (filePath as NSString).deletingLastPathComponent
            }
        case .imageViewer(let imageState):
            if !imageState.filePath.isEmpty {
                return (imageState.filePath as NSString).deletingLastPathComponent
            }
        case .markdownPreview(let markdownState):
            if !markdownState.filePath.isEmpty {
                return (markdownState.filePath as NSString).deletingLastPathComponent
            }
        case .pluginView:
            break
        }
        return fallback.isEmpty ? workspacePath : fallback
    }
}
