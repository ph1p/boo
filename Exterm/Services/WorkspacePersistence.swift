import Cocoa

/// Persists and restores workspace layouts (split trees, panes, tabs, CWDs).
enum WorkspacePersistence {
    private static let filePath = (ExtermPaths.configDir as NSString).appendingPathComponent("workspaces.json")

    // MARK: - Snapshot types

    struct TabSnapshot: Codable {
        let id: UUID
        let title: String
        let workingDirectory: String
    }

    struct PaneSnapshot: Codable {
        let id: UUID
        let tabs: [TabSnapshot]
        let activeTabIndex: Int
    }

    struct WorkspaceSnapshot: Codable {
        let id: UUID
        let folderPath: String
        let customName: String?
        let color: String  // WorkspaceColor rawValue
        let customColorHex: String?
        let isPinned: Bool
        let splitTree: SplitTree
        let panes: [PaneSnapshot]
        let activePaneID: UUID
        let currentDirectory: String
    }

    struct AppSnapshot: Codable {
        let workspaces: [WorkspaceSnapshot]
        let activeWorkspaceIndex: Int
    }

    // MARK: - Save

    static func save(appState: AppState) {
        let snapshots = appState.workspaces.map { ws -> WorkspaceSnapshot in
            let paneSnapshots = ws.splitTree.leafIDs.compactMap { paneID -> PaneSnapshot? in
                guard let pane = ws.pane(for: paneID) else { return nil }
                let tabs = pane.tabs.map { TabSnapshot(id: $0.id, title: $0.title, workingDirectory: $0.workingDirectory) }
                return PaneSnapshot(id: pane.id, tabs: tabs, activeTabIndex: pane.activeTabIndex)
            }

            return WorkspaceSnapshot(
                id: ws.id,
                folderPath: ws.folderPath,
                customName: ws.customName,
                color: ws.color.rawValue,
                customColorHex: ws.customColor.map { hexFromNSColor($0) },
                isPinned: ws.isPinned,
                splitTree: ws.splitTree,
                panes: paneSnapshots,
                activePaneID: ws.activePaneID,
                currentDirectory: ws.currentDirectory
            )
        }

        let appSnapshot = AppSnapshot(
            workspaces: snapshots,
            activeWorkspaceIndex: appState.activeWorkspaceIndex
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(appSnapshot)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            NSLog("[WorkspacePersistence] Save failed: \(error)")
        }
    }

    // MARK: - Load

    static func load() -> AppSnapshot? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            return try JSONDecoder().decode(AppSnapshot.self, from: data)
        } catch {
            NSLog("[WorkspacePersistence] Load failed: \(error)")
            return nil
        }
    }

    /// Restore a Workspace from a snapshot. Creates the Pane objects with tabs but
    /// does NOT create terminal surfaces — the caller does that when activating.
    static func restoreWorkspace(from snapshot: WorkspaceSnapshot) -> Workspace {
        let ws = Workspace(folderPath: snapshot.folderPath, id: snapshot.id, splitTree: snapshot.splitTree, activePaneID: snapshot.activePaneID)
        ws.customName = snapshot.customName
        ws.color = WorkspaceColor(rawValue: snapshot.color) ?? .none
        ws.customColor = snapshot.customColorHex.flatMap { nsColorFromHex($0) }
        ws.isPinned = snapshot.isPinned

        // Restore panes
        for paneSnap in snapshot.panes {
            let pane = Pane(id: paneSnap.id)
            for tab in paneSnap.tabs {
                pane.addTab(id: tab.id, title: tab.title, workingDirectory: tab.workingDirectory)
            }
            if paneSnap.activeTabIndex >= 0, paneSnap.activeTabIndex < paneSnap.tabs.count {
                pane.setActiveTab(paneSnap.activeTabIndex)
            }
            ws.restorePane(pane)
        }

        return ws
    }

    // MARK: - Color helpers

    private static func hexFromNSColor(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    private static func nsColorFromHex(_ hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt32(h, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8) & 0xFF) / 255,
            blue: CGFloat(val & 0xFF) / 255,
            alpha: 1
        )
    }
}
