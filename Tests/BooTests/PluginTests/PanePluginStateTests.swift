import XCTest

@testable import Boo

/// Tests for per-tab sidebar plugin state persistence.
/// Exercises the state-management logic used by MainWindowController
/// via TabState.expandedPluginIDs on each Pane.Tab.
@MainActor
final class PanePluginStateTests: XCTestCase {

    // MARK: - Expand/collapse persists per tab

    func testExpandCollapsePersistsToActiveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        // Expand bookmarks
        var expanded = pane.activeTab!.state.expandedPluginIDs
        expanded.insert("bookmarks")
        pane.updatePluginState(at: 0, expanded: expanded)

        XCTAssertTrue(
            pane.activeTab!.state.expandedPluginIDs.contains("bookmarks"),
            "Expanded state should be persisted after toggle")

        // Collapse bookmarks
        expanded.remove("bookmarks")
        pane.updatePluginState(at: 0, expanded: expanded)

        XCTAssertFalse(
            pane.activeTab!.state.expandedPluginIDs.contains("bookmarks"),
            "Collapsed state should be persisted after toggle")
    }

    func testExpandedStateIsPerTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        // Expand "git-panel" only in tab 0
        pane.updatePluginState(at: 0, expanded: ["git-panel"])
        pane.updatePluginState(at: 1, expanded: [])

        pane.setActiveTab(0)
        XCTAssertTrue(pane.activeTab!.state.expandedPluginIDs.contains("git-panel"))

        pane.setActiveTab(1)
        XCTAssertFalse(
            pane.activeTab!.state.expandedPluginIDs.contains("git-panel"),
            "Expanded state of tab 0 should not bleed into tab 1")
    }

    // MARK: - Sidebar panel metrics persist per tab

    func testSidebarPanelMetricsPersistToActiveTabState() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        let terminalID = pane.activeTab!.id
        let heights: [String: CGFloat] = ["bookmarks": 188, "git-panel": 144]
        let offsets: [String: CGPoint] = [
            "\(terminalID.uuidString):bookmarks": CGPoint(x: 0, y: 37)
        ]

        pane.updatePluginState(
            at: 0,
            expanded: pane.activeTab!.state.expandedPluginIDs,
            sidebarSectionHeights: heights,
            sidebarScrollOffsets: offsets
        )

        XCTAssertEqual(pane.activeTab!.state.sidebarSectionHeights, heights)
        XCTAssertEqual(
            pane.activeTab!.state.sidebarScrollOffsets["\(terminalID.uuidString):bookmarks"]?.y ?? -1,
            37,
            accuracy: 0.1
        )
    }
}
