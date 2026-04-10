import Cocoa
import Foundation

// MARK: - Codable session snapshot types

struct SessionTab: Codable {
    let title: String
    let workingDirectory: String
    // Remote sessions are intentionally omitted — only local state is persisted.
    // Sidebar state — optional so old session.json files decode without error.
    let expandedPluginIDs: [String]?
    let userCollapsedSectionIDs: [String]?
    let sidebarSectionHeights: [String: Double]?
    let sidebarScrollOffsets: [String: [Double]]?
    let sidebarSectionOrder: [String: [String]]?
    let selectedPluginTabID: String?
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
}

struct SessionSnapshot: Codable {
    let activeWorkspaceIndex: Int
    let workspaces: [SessionWorkspace]
}

// MARK: - SessionStore

enum SessionStore {
    private static var _testFilePath: String? = nil

    /// Override the storage path. Pass `nil` to revert to the default. Tests only.
    static func overrideFilePathForTesting(_ path: String?) {
        _testFilePath = path
    }

    private static var sessionFile: String {
        _testFilePath ?? BooPaths.configDir.appendingPathComponent("session.json")
    }

    static func save(appState: AppState) {
        let workspaces = appState.workspaces.map { ws -> SessionWorkspace in
            let panes = ws.panes.values.map { pane -> SessionPane in
                let tabs = pane.tabs.map { tab in
                    SessionTab(
                        title: tab.title,
                        workingDirectory: tab.workingDirectory,
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
                activePaneID: ws.activePaneID
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
            NSLog("[SessionStore] Failed to save session: \(error)")
        }
    }

    /// Returns nil when no session file exists or the file cannot be decoded.
    static func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: sessionFile) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            NSLog("[SessionStore] Failed to load session: \(error)")
            return nil
        }
    }

    /// Reconstruct Workspace objects from a snapshot, skipping any workspaces
    /// whose folderPath no longer exists on disk.
    static func workspaces(from snapshot: SessionSnapshot) -> [Workspace] {
        snapshot.workspaces.compactMap { sw in
            // Only restore workspaces whose root folder still exists.
            guard FileManager.default.fileExists(atPath: sw.folderPath) else {
                NSLog("[SessionStore] Skipping workspace at \(sw.folderPath) — path not found")
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

            // Build a lookup so we can match panes to split-tree leaf IDs
            let paneByID = Dictionary(uniqueKeysWithValues: sw.panes.map { ($0.id, $0) })
            let leafIDs = sw.splitTree.leafIDs

            for leafID in leafIDs {
                let pane = Pane(id: leafID)
                if let sp = paneByID[leafID], !sp.tabs.isEmpty {
                    for tab in sp.tabs {
                        pane.addTab(workingDirectory: tab.workingDirectory, title: tab.title)
                        let idx = pane.tabs.count - 1
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

            return ws
        }
    }
}
