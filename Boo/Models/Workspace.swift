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
        case .blue: return NSColor(red: 77 / 255, green: 143 / 255, blue: 232 / 255, alpha: 1)
        case .purple: return NSColor(red: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 1)
        case .green: return NSColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)
        case .orange: return NSColor(red: 255 / 255, green: 159 / 255, blue: 10 / 255, alpha: 1)
        case .red: return NSColor(red: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
        case .yellow: return NSColor(red: 255 / 255, green: 214 / 255, blue: 10 / 255, alpha: 1)
        case .pink: return NSColor(red: 255 / 255, green: 55 / 255, blue: 95 / 255, alpha: 1)
        }
    }

    var label: String { rawValue.capitalized }
}

struct SidebarWorkspaceState {
    /// Overridden visibility for this workspace. nil = use global default.
    var isVisible: Bool? = nil
    /// Overridden sidebar width for this workspace. nil = use AppSettings.sidebarWidth.
    var width: CGFloat? = nil
}

final class Workspace {
    static func defaultSidebarState() -> SidebarWorkspaceState {
        SidebarWorkspaceState(
            isVisible: !AppSettings.shared.sidebarDefaultHidden,
            width: AppSettings.shared.sidebarWidth
        )
    }

    let id: UUID
    var folderPath: String

    var customName: String?
    var color: WorkspaceColor = .none
    var customColor: NSColor?  // overrides color when set
    var isPinned: Bool = false

    /// Per-workspace sidebar visibility and width overrides.
    var sidebarState: SidebarWorkspaceState = Workspace.defaultSidebarState()

    /// Resolved color: custom color takes precedence, then preset, then nil.
    var resolvedColor: NSColor? {
        customColor ?? color.nsColor
    }

    var displayName: String {
        customName ?? folderPath.lastPathComponent
    }

    var splitTree: SplitTree
    private(set) var panes: [UUID: Pane] = [:]
    var activePaneID: UUID {
        didSet {
            if activePaneID != oldValue {
                // Keep a most-recently-focused history (no duplicates).
                focusHistory.removeAll { $0 == activePaneID }
                focusHistory.append(activePaneID)
                // Cap size to avoid unbounded growth.
                if focusHistory.count > 32 {
                    focusHistory.removeFirst()
                }
            }
        }
    }
    /// Most-recently-focused pane IDs (oldest first, newest last).
    private var focusHistory: [UUID] = []

    init(folderPath: String) {
        self.id = UUID()
        self.folderPath = folderPath
        let rootID = UUID()
        self.splitTree = .leaf(id: rootID)
        self.activePaneID = rootID

        // Create the root pane with one tab
        let pane = Pane(id: rootID)
        _ = pane.addTab(workingDirectory: folderPath)
        panes[rootID] = pane
    }

    /// Restore a workspace from persisted state.
    init(folderPath: String, id: UUID, splitTree: SplitTree, activePaneID: UUID) {
        self.id = id
        self.folderPath = folderPath
        self.splitTree = splitTree
        self.activePaneID = activePaneID
    }

    /// Add a pre-built pane (used during restore).
    @discardableResult
    func restorePane(_ pane: Pane) -> Bool {
        guard splitTree.leafIDs.contains(pane.id) else {
            debugLog(
                "[WorkspaceSwitch] rejectedPaneRestore workspace=\(id.uuidString) pane=\(pane.id.uuidString)"
            )
            return false
        }
        panes[pane.id] = pane
        return true
    }

    func pane(for id: UUID) -> Pane? { panes[id] }

    var totalTabCount: Int { panes.values.reduce(0) { $0 + $1.tabs.count } }

    func normalizePaneState() {
        if splitTree.leafIDs.isEmpty {
            let rootID = UUID()
            splitTree = .leaf(id: rootID)
            activePaneID = rootID
        }

        let leafIDs = splitTree.leafIDs
        let leafSet = Set(leafIDs)

        for paneID in panes.keys where !leafSet.contains(paneID) {
            panes[paneID]?.stopAll()
            panes.removeValue(forKey: paneID)
        }

        for leafID in leafIDs {
            let pane: Pane
            if let existing = panes[leafID] {
                pane = existing
            } else {
                pane = Pane(id: leafID)
                panes[leafID] = pane
            }

            if pane.tabs.isEmpty {
                _ = pane.addTab(workingDirectory: folderPath)
            }
        }

        if !leafSet.contains(activePaneID) {
            activePaneID = leafIDs.first ?? activePaneID
        }
    }

    func remapPaneIDs(_ mapping: [UUID: UUID]) {
        guard !mapping.isEmpty else { return }

        splitTree = splitTree.remappingLeafIDs(mapping)

        var remappedPanes: [UUID: Pane] = [:]
        for (paneID, pane) in panes {
            let remappedID = mapping[paneID] ?? paneID
            remappedPanes[remappedID] =
                remappedID == paneID ? pane : pane.cloned(withID: remappedID)
        }
        panes = remappedPanes

        activePaneID = mapping[activePaneID] ?? activePaneID

        var remappedFocusHistory: [UUID] = []
        for paneID in focusHistory {
            let remappedID = mapping[paneID] ?? paneID
            if !remappedFocusHistory.contains(remappedID) {
                remappedFocusHistory.append(remappedID)
            }
        }
        focusHistory = remappedFocusHistory
    }

    @discardableResult
    func splitPane(_ paneID: UUID, direction: SplitTree.SplitDirection) -> UUID {
        let (newTree, newID) = splitTree.splitting(leafID: paneID, direction: direction)
        splitTree = newTree

        // New pane starts with empty title to avoid briefly showing the old pane's process name.
        // CWD follows the user's setting: inherit from source pane or use workspace default folder.
        let cwd: String
        if AppSettings.shared.newTabCwdMode == .samePath {
            cwd = panes[paneID]?.activeTab?.workingDirectory ?? folderPath
        } else {
            cwd = folderPath
        }
        let newPane = Pane(id: newID)
        _ = newPane.addTab(workingDirectory: cwd, title: "")
        panes[newID] = newPane

        return newID
    }

    func closePane(_ paneID: UUID) -> Bool {
        // Find the closest sibling before removing
        let sibling = splitTree.siblingLeafID(of: paneID)
        guard let newTree = splitTree.removing(leafID: paneID) else {
            return false
        }
        panes[paneID]?.stopAll()
        panes.removeValue(forKey: paneID)
        splitTree = newTree
        focusHistory.removeAll { $0 == paneID }
        if activePaneID == paneID {
            // Restore the most recently focused pane that still exists,
            // fall back to the sibling, then the first leaf.
            let remaining = Set(splitTree.leafIDs)
            let fromHistory = focusHistory.last(where: { remaining.contains($0) })
            activePaneID = fromHistory ?? sibling ?? splitTree.leafIDs.first ?? UUID()
        }
        return true
    }

    func equalizeSplits() {
        splitTree = equalizeSplitRatios(splitTree)
    }

    private func equalizeSplitRatios(_ tree: SplitTree) -> SplitTree {
        switch tree {
        case .leaf:
            return tree
        case .split(let direction, let first, let second, _):
            return .split(
                direction: direction,
                first: equalizeSplitRatios(first),
                second: equalizeSplitRatios(second),
                ratio: 0.5
            )
        }
    }

    func stopAll() {
        for (_, pane) in panes { pane.stopAll() }
        panes.removeAll()
    }
}
