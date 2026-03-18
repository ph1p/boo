import Foundation

/// A pane is a leaf in the split tree. It has its own tab bar with multiple terminal tabs.
final class Pane {
    let id: UUID

    struct Tab {
        let id: UUID
        var title: String
        var workingDirectory: String
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
            title: (workingDirectory as NSString).lastPathComponent,
            workingDirectory: workingDirectory
        )
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
    }

    /// Restore a tab with a specific ID and title (used during workspace restore).
    @discardableResult
    func addTab(id: UUID, title: String, workingDirectory: String) -> Int {
        let tab = Tab(id: id, title: title, workingDirectory: workingDirectory)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
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
        tabs[index].title = title
    }

    func updateWorkingDirectory(at index: Int, _ path: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].workingDirectory = path
        tabs[index].title = (path as NSString).lastPathComponent
    }

    func stopAll() {
        tabs.removeAll()
    }
}
