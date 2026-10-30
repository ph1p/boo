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

    /// A color that stays the same for a project across launches and machines:
    /// FNV-1a of its git root (or the folder itself), since `Hasher` is seeded
    /// per process.
    static func auto(forFolder folder: String, fileManager: FileManager = .default) -> WorkspaceColor {
        let key = gitRoot(of: folder, fileManager: fileManager) ?? (folder as NSString).standardizingPath
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let palette = allCases.filter { $0 != .none }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Nearest folder at or above `folder` holding `.git` (a directory, or a
    /// file in worktrees and submodules).
    static func gitRoot(of folder: String, fileManager: FileManager = .default) -> String? {
        var dir = ((folder as NSString).expandingTildeInPath as NSString).standardizingPath
        while !dir.isEmpty {
            if fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
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
    /// The tmux window (`@N`) this workspace shows; such workspaces aren't saved.
    var tmuxWindowID: String?

    /// Per-workspace sidebar visibility and width overrides.
    var sidebarState: SidebarWorkspaceState = Workspace.defaultSidebarState()

    /// Resolved color: custom color takes precedence, then preset, then nil.
    var resolvedColor: NSColor? {
        customColor ?? color.nsColor
    }

    var displayName: String {
        customName ?? folderPath.lastPathComponent
    }

    var hasActivity: Bool {
        panes.values.contains { pane in
            pane.tabs.contains { $0.state.hasActivity }
        }
    }

    /// Every tab's progress report, for the workspace pill and the dock tile.
    var progressReports: [TerminalProgress] {
        panes.values.flatMap { pane in pane.tabs.compactMap(\.state.progress) }
    }

    var splitTree: SplitTree {
        didSet {
            // Zoom survives ratio changes only; a pane added, closed or moved shows the layout again.
            if zoomedPaneID != nil, !oldValue.hasSameStructure(as: splitTree) { zoomedPaneID = nil }
        }
    }
    /// Pane filling the whole workspace while the others stay hidden.
    /// Per workspace and never persisted.
    var zoomedPaneID: UUID? {
        didSet {
            if let id = zoomedPaneID, !splitTree.containsLeafID(id) || splitTree.leafCount < 2 { zoomedPaneID = nil }
        }
    }
    /// Tree the split container renders: just the zoomed pane while zoomed.
    var displayedTree: SplitTree {
        zoomedPaneID.map { .leaf(id: $0) } ?? splitTree
    }
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

    /// Working directory of the active pane's active tab; nil when unknown.
    var activeWorkingDirectory: String? {
        guard let cwd = pane(for: activePaneID)?.activeTab?.workingDirectory, !cwd.isEmpty else { return nil }
        return cwd
    }

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
    func splitPane(_ paneID: UUID, direction: SplitTree.SplitDirection, cwd: String? = nil) -> UUID? {
        let (newTree, newID) = splitTree.splitting(leafID: paneID, direction: direction)
        guard let newID = newID else {
            booLog(
                .debug, .terminal,
                "[Workspace] splitPane: leafID \(paneID.uuidString.prefix(8)) not found — no-op")
            return nil
        }
        splitTree = newTree

        // New pane starts with empty title to avoid briefly showing the old pane's process name.
        // CWD follows the user's setting: inherit from source pane or use workspace default folder.
        let directory: String
        if let cwd {
            directory = cwd
        } else if AppSettings.shared.newTabCwdMode == .samePath {
            directory = panes[paneID]?.activeTab?.workingDirectory ?? folderPath
        } else {
            directory = folderPath
        }
        let newPane = Pane(id: newID)
        _ = newPane.addTab(workingDirectory: directory, title: "")
        panes[newID] = newPane

        return newID
    }

    /// Add a pane on `edge` of `paneID`, or along that whole side of the
    /// workspace. A whole-side pane gets the same share as each pane already
    /// lined up on that axis.
    @discardableResult
    func splitPane(
        _ paneID: UUID, toward edge: PaneDirection, wholeWorkspace: Bool = false, cwd: String? = nil
    ) -> UUID? {
        let previous = splitTree
        guard let newID = splitPane(paneID, direction: edge.axis, cwd: cwd) else { return nil }
        if wholeWorkspace {
            let weight = CGFloat(previous.weight(along: edge.axis))
            splitTree =
                edge.isForward
                ? .split(direction: edge.axis, first: previous, second: .leaf(id: newID), ratio: weight / (weight + 1))
                : .split(direction: edge.axis, first: .leaf(id: newID), second: previous, ratio: 1 / (weight + 1))
        } else if !edge.isForward {
            splitTree = splitTree.swappingChildrenAtParent(of: newID)
        }
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

    /// Lays the workspace out as `tree`: `newPanes` fill its new leaves, and
    /// panes missing from it stop. Returns the IDs of the panes it dropped.
    @discardableResult
    func adopt(tree: SplitTree, newPanes: [Pane]) -> [UUID] {
        splitTree = tree
        for pane in newPanes { panes[pane.id] = pane }
        let leaves = Set(tree.leafIDs)
        let gone = panes.keys.filter { !leaves.contains($0) }
        for id in gone { panes.removeValue(forKey: id)?.stopAll() }
        focusHistory.removeAll { !leaves.contains($0) }
        if !leaves.contains(activePaneID) {
            activePaneID = focusHistory.last ?? tree.leafIDs.first ?? activePaneID
        }
        return gone
    }

    func equalizeSplits() {
        splitTree = splitTree.equalized()
    }

    func stopAll() {
        for (_, pane) in panes { pane.stopAll() }
        panes.removeAll()
    }
}
