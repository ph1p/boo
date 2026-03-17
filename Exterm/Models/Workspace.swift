import Cocoa

enum WorkspaceColor: String, CaseIterable {
    case none = "none"
    case blue = "blue"
    case purple = "purple"
    case green = "green"
    case orange = "orange"
    case red = "red"
    case yellow = "yellow"
    case pink = "pink"

    var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .blue: return NSColor(red: 77/255, green: 143/255, blue: 232/255, alpha: 1)
        case .purple: return NSColor(red: 139/255, green: 92/255, blue: 246/255, alpha: 1)
        case .green: return NSColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1)
        case .orange: return NSColor(red: 255/255, green: 159/255, blue: 10/255, alpha: 1)
        case .red: return NSColor(red: 255/255, green: 69/255, blue: 58/255, alpha: 1)
        case .yellow: return NSColor(red: 255/255, green: 214/255, blue: 10/255, alpha: 1)
        case .pink: return NSColor(red: 255/255, green: 55/255, blue: 95/255, alpha: 1)
        }
    }

    var label: String { rawValue.capitalized }
}

final class Workspace {
    let id: UUID
    let folderPath: String

    var customName: String?
    var color: WorkspaceColor = .none
    var isPinned: Bool = false

    var displayName: String {
        customName ?? (folderPath as NSString).lastPathComponent
    }

    private(set) var splitTree: SplitTree
    private(set) var panes: [UUID: Pane] = [:]
    var activePaneID: UUID

    private(set) var currentDirectory: String
    var onDirectoryChanged: ((String) -> Void)?

    init(folderPath: String) {
        self.id = UUID()
        self.folderPath = folderPath
        self.currentDirectory = folderPath
        let rootID = UUID()
        self.splitTree = .leaf(id: rootID)
        self.activePaneID = rootID

        // Create the root pane with one tab
        let pane = Pane(id: rootID)
        _ = pane.addTab(workingDirectory: folderPath)
        panes[rootID] = pane
    }

    func pane(for id: UUID) -> Pane? { panes[id] }

    @discardableResult
    func splitPane(_ paneID: UUID, direction: SplitTree.SplitDirection) -> UUID {
        let (newTree, newID) = splitTree.splitting(leafID: paneID, direction: direction)
        splitTree = newTree

        // New pane inherits cwd from the source pane
        let cwd = panes[paneID]?.activeSession?.currentDirectory ?? folderPath
        let newPane = Pane(id: newID)
        _ = newPane.addTab(workingDirectory: cwd)
        panes[newID] = newPane

        return newID
    }

    func closePane(_ paneID: UUID) -> Bool {
        panes[paneID]?.stopAll()
        panes.removeValue(forKey: paneID)

        if let newTree = splitTree.removing(leafID: paneID) {
            splitTree = newTree
            if activePaneID == paneID {
                activePaneID = splitTree.leafIDs.first ?? UUID()
            }
            return true
        }
        return false
    }

    func handleDirectoryChange(_ newPath: String) {
        guard newPath != currentDirectory else { return }
        currentDirectory = newPath
        onDirectoryChanged?(newPath)
    }

    func stopAll() {
        for (_, pane) in panes { pane.stopAll() }
        panes.removeAll()
    }
}
