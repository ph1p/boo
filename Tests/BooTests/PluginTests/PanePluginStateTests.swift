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

    func testNewPaneTabInheritsSidebarPanelMetrics() {
        let parentPane = Pane()
        _ = parentPane.addTab(workingDirectory: "/tmp")
        let parentTerminalID = parentPane.activeTab!.id
        let heights: [String: CGFloat] = ["bookmarks": 211]
        let offsets: [String: CGPoint] = [
            "\(parentTerminalID.uuidString):bookmarks": CGPoint(x: 0, y: 52)
        ]
        parentPane.updatePluginState(
            at: 0,
            expanded: ["file-tree-local", "bookmarks"],
            sidebarSectionHeights: heights,
            sidebarScrollOffsets: offsets,
            selectedPluginTabID: "file-tree-local"
        )

        let newPane = Pane()
        _ = newPane.addTab(workingDirectory: "/tmp")
        let inherited = parentPane.activeTab!.state
        newPane.updatePluginState(
            at: 0,
            expanded: inherited.expandedPluginIDs,
            sidebarSectionHeights: inherited.sidebarSectionHeights,
            sidebarScrollOffsets: inherited.sidebarScrollOffsets,
            selectedPluginTabID: inherited.selectedPluginTabID
        )

        XCTAssertEqual(newPane.activeTab!.state.sidebarSectionHeights, heights)
        XCTAssertEqual(
            newPane.activeTab!.state.sidebarScrollOffsets["\(parentTerminalID.uuidString):bookmarks"]?.y ?? -1,
            52,
            accuracy: 0.1
        )
        XCTAssertEqual(newPane.activeTab!.state.selectedPluginTabID, "file-tree-local")
    }

    // MARK: - Context visibility filters correctly

    func testGitPluginHiddenWithoutGitContext() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let noGitContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let result = registry.runCycle(baseContext: noGitContext, reason: .focusChanged)
        XCTAssertFalse(
            result.visiblePluginIDs.contains("git-panel"),
            "Git plugin should be hidden when there is no git context")
    }

    func testGitPluginVisibleWithGitContext() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let gitContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: TerminalContext.GitContext(
                branch: "main", repoRoot: "/repo", isDirty: false,
                changedFileCount: 0, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil
            ),
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let result = registry.runCycle(baseContext: gitContext, reason: .focusChanged)
        XCTAssertTrue(
            result.visiblePluginIDs.contains("git-panel"),
            "Git plugin should be visible when git context is present")
    }
}
