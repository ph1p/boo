import Foundation

/// A pane is a leaf in the split tree. It has its own tab bar with multiple terminal sessions.
final class Pane {
    let id: UUID

    struct Tab {
        let id: UUID
        var session: TerminalSession?
        var title: String
        let workingDirectory: String
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex: Int = -1

    var activeTab: Tab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var activeSession: TerminalSession? { activeTab?.session }

    init(id: UUID = UUID()) {
        self.id = id
    }

    func addTab(workingDirectory: String) -> Int {
        let tab = Tab(
            id: UUID(),
            session: nil,
            title: (workingDirectory as NSString).lastPathComponent,
            workingDirectory: workingDirectory
        )
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
    }

    func removeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].session?.stop()
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func setActiveTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }

    func setSession(_ session: TerminalSession, forTabAt index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].session = session
    }

    func updateTitle(at index: Int, _ title: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].title = title
    }

    func stopAll() {
        for tab in tabs {
            tab.session?.stop()
        }
        tabs.removeAll()
    }
}
