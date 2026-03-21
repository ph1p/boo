import Foundation

/// Per-tab state — single source of truth for everything a tab owns.
struct TabState {
    // Terminal
    var workingDirectory: String
    var remoteSession: RemoteSessionType?
    var remoteWorkingDirectory: String?
    var shellPID: pid_t = 0
    var title: String
    var foregroundProcess: String = ""

    // Plugin UI State
    var openPluginIDs: Set<String> = Set(AppSettings.shared.defaultEnabledPluginIDs)
    var expandedPluginIDs: Set<String> = ["file-tree-local", "file-tree-remote"]
}

/// A pane is a leaf in the split tree. It has its own tab bar with multiple terminal tabs.
final class Pane {
    let id: UUID

    struct Tab {
        let id: UUID
        var state: TabState

        // Convenience accessors for backward compatibility
        var title: String {
            get { state.title }
            set { state.title = newValue }
        }
        var workingDirectory: String {
            get { state.workingDirectory }
            set { state.workingDirectory = newValue }
        }
        var remoteSession: RemoteSessionType? {
            get { state.remoteSession }
            set { state.remoteSession = newValue }
        }
        var remoteWorkingDirectory: String? {
            get { state.remoteWorkingDirectory }
            set { state.remoteWorkingDirectory = newValue }
        }
        var shellPID: pid_t {
            get { state.shellPID }
            set { state.shellPID = newValue }
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex: Int = -1

    var activeTab: Tab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    init(id: UUID = UUID()) {
        self.id = id
    }

    @discardableResult
    func addTab(workingDirectory: String) -> Int {
        let tab = Tab(
            id: UUID(),
            state: TabState(
                workingDirectory: workingDirectory,
                title: (workingDirectory as NSString).lastPathComponent
            )
        )
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
    }

    /// Restore a tab with a specific ID and title (used during workspace restore).
    @discardableResult
    func addTab(id: UUID, title: String, workingDirectory: String) -> Int {
        let tab = Tab(
            id: id,
            state: TabState(
                workingDirectory: workingDirectory,
                title: title
            )
        )
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabs.count,
            destinationIndex >= 0, destinationIndex < tabs.count,
            sourceIndex != destinationIndex
        else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)
        // Keep active tab pointing at the same tab
        if activeTabIndex == sourceIndex {
            activeTabIndex = destinationIndex
        } else if sourceIndex < activeTabIndex && destinationIndex >= activeTabIndex {
            activeTabIndex -= 1
        } else if sourceIndex > activeTabIndex && destinationIndex <= activeTabIndex {
            activeTabIndex += 1
        }
    }

    func removeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func setActiveTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }

    func updateTitle(at index: Int, _ title: String) {
        guard index >= 0, index < tabs.count else { return }
        // Skip transient command titles that flash briefly before the shell
        // prompt updates with the final state (e.g. "cd /path", "git switch branch")
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("cd ") || trimmed.hasPrefix("git switch ")
            || trimmed.hasPrefix("git checkout ")
        {
            return
        }
        tabs[index].title = title
    }

    func updateWorkingDirectory(at index: Int, _ path: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].workingDirectory = path
    }

    func updateRemoteSession(at index: Int, _ session: RemoteSessionType?) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].remoteSession = session
        if session == nil {
            tabs[index].remoteWorkingDirectory = nil
        }
    }

    func updateRemoteWorkingDirectory(at index: Int, _ path: String?) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].remoteWorkingDirectory = path
    }

    func updateForegroundProcess(at index: Int, _ process: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.foregroundProcess = process
    }

    func updateShellPID(at index: Int, _ pid: pid_t) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].shellPID = pid
    }

    func updatePluginState(at index: Int, open: Set<String>, expanded: Set<String>) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.openPluginIDs = Self.migratePluginIDs(open)
        tabs[index].state.expandedPluginIDs = Self.migratePluginIDs(expanded)
    }

    /// Migrate old "file-tree" plugin ID to the new local/remote pair.
    static func migratePluginIDs(_ ids: Set<String>) -> Set<String> {
        guard ids.contains("file-tree") else { return ids }
        var migrated = ids
        migrated.remove("file-tree")
        migrated.insert("file-tree-local")
        migrated.insert("file-tree-remote")
        return migrated
    }

    /// Remove and return a tab without destroying its view. Used for cross-pane drag.
    @discardableResult
    func extractTab(at index: Int) -> Tab? {
        guard index >= 0, index < tabs.count else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = max(tabs.count - 1, 0)
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        return tab
    }

    /// Insert an existing tab at a specific index. Used for cross-pane drag.
    func insertTab(_ tab: Tab, at index: Int) {
        let clampedIndex = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clampedIndex)
        activeTabIndex = clampedIndex
    }

    func stopAll() {
        tabs.removeAll()
    }
}
