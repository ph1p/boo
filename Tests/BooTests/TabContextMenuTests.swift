import XCTest

@testable import Boo

/// Tests for the model conditions driving tab right-click context menu items:
/// - "Close Tab" vs "Close Workspace" label logic
/// - "Move Tab to Workspace" submenu content
/// - paneViewIsOnlyPaneInWorkspace
/// - paneViewWorkspaceNames (via AppState simulation)
final class TabContextMenuTests: XCTestCase {

    // MARK: - Close label: isOnlyTabInWorkspace equivalent

    func testCloseWorkspaceLabelWhenSinglePaneSingleTab() {
        // Condition: pane.tabs.count == 1 AND pane is the only pane in workspace
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(ws.panes.count, 1)
        // → should show "Close Workspace"
        let showsCloseWorkspace = pane.tabs.count == 1 && ws.panes.count == 1
        XCTAssertTrue(showsCloseWorkspace)
    }

    func testCloseTabLabelWhenMultipleTabs() {
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        _ = pane.addTab(workingDirectory: "/b")
        // pane.tabs.count == 2 → "Close Tab"
        let showsCloseWorkspace = pane.tabs.count == 1 && ws.panes.count == 1
        XCTAssertFalse(showsCloseWorkspace)
    }

    func testCloseTabLabelWhenSingleTabButMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        _ = ws.splitPane(ws.activePaneID, direction: .horizontal)
        let pane = ws.pane(for: ws.activePaneID)!
        // pane has 1 tab, but workspace has 2 panes → "Close Tab" (not workspace)
        let showsCloseWorkspace = pane.tabs.count == 1 && ws.panes.count == 1
        XCTAssertFalse(showsCloseWorkspace)
    }

    func testCloseWorkspaceLabelRequiresBothConditions() {
        let ws = Workspace(folderPath: "/tmp")
        _ = ws.splitPane(ws.activePaneID, direction: .vertical)
        let pane = ws.pane(for: ws.activePaneID)!
        _ = pane.addTab(workingDirectory: "/extra")
        // pane has 2 tabs, workspace has 2 panes — neither condition met
        let showsCloseWorkspace = pane.tabs.count == 1 && ws.panes.count == 1
        XCTAssertFalse(showsCloseWorkspace)
    }

    // MARK: - paneViewIsOnlyPaneInWorkspace

    func testIsOnlyPaneWhenSinglePane() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertEqual(ws.panes.count, 1)
        // Simulates paneViewIsOnlyPaneInWorkspace returning true
        let isOnly = ws.panes.count == 1
        XCTAssertTrue(isOnly)
    }

    func testIsNotOnlyPaneAfterSplit() {
        let ws = Workspace(folderPath: "/tmp")
        _ = ws.splitPane(ws.activePaneID, direction: .horizontal)
        let isOnly = ws.panes.count == 1
        XCTAssertFalse(isOnly)
    }

    func testIsOnlyPaneRestoredAfterClose() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        XCTAssertFalse(ws.panes.count == 1)

        _ = ws.closePane(id2)
        XCTAssertTrue(ws.panes.count == 1)
    }

    // MARK: - paneViewWorkspaceNames: other workspaces list

    func testNoOtherWorkspacesWhenAlone() {
        let state = AppState()
        let ws = Workspace(folderPath: "/only")
        state.addWorkspace(ws)

        let paneID = ws.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })!
        let others = state.workspaces.enumerated().compactMap { (i, w) -> String? in
            w.id == sourceWS.id ? nil : w.displayName
        }
        XCTAssertTrue(others.isEmpty)
    }

    func testOtherWorkspacesListedCorrectly() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws3 = Workspace(folderPath: "/c")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(ws3)

        let paneID = ws1.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })!
        let others = state.workspaces.enumerated().compactMap { (i, w) -> (index: Int, name: String)? in
            w.id == sourceWS.id ? nil : (index: i, name: w.displayName)
        }
        XCTAssertEqual(others.count, 2)
        XCTAssertTrue(others.contains(where: { $0.name == "b" }))
        XCTAssertTrue(others.contains(where: { $0.name == "c" }))
        XCTAssertFalse(others.contains(where: { $0.name == "a" }))
    }

    func testOtherWorkspacesCorrectIndexesForSubmenu() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws3 = Workspace(folderPath: "/c")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(ws3)

        // Source is ws2 (index 1)
        let paneID = ws2.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })!
        let others = state.workspaces.enumerated().compactMap { (i, w) -> (index: Int, name: String)? in
            w.id == sourceWS.id ? nil : (index: i, name: w.displayName)
        }
        // Should include ws1 at index 0 and ws3 at index 2 — NOT ws2
        XCTAssertEqual(others.count, 2)
        XCTAssertTrue(others.contains(where: { $0.index == 0 && $0.name == "a" }))
        XCTAssertTrue(others.contains(where: { $0.index == 2 && $0.name == "c" }))
        XCTAssertFalse(others.contains(where: { $0.index == 1 }))
    }

    func testSubmenuUsesDisplayNameForCustomNamedWorkspace() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/Users/dev/myproject")
        ws1.customName = "My Project"
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        let paneID = ws2.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })!
        let others = state.workspaces.enumerated().compactMap { (i, w) -> (index: Int, name: String)? in
            w.id == sourceWS.id ? nil : (index: i, name: w.displayName)
        }
        XCTAssertEqual(others.first?.name, "My Project")
    }

    // MARK: - Move-to-workspace model execution

    func testMoveTabToWorkspaceIncreasesDestTabCount() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        _ = ws1.pane(for: ws1.activePaneID)!.addTab(workingDirectory: "/second")
        let pane1 = ws1.pane(for: ws1.activePaneID)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!

        let tab = pane1.extractTab(at: 0)!
        pane2.insertTab(tab, at: pane2.tabs.count)

        XCTAssertEqual(pane2.tabs.count, 2)
    }

    func testMoveTabToWorkspaceDecreasesSourceTabCount() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        _ = ws1.pane(for: ws1.activePaneID)!.addTab(workingDirectory: "/second")
        let pane1 = ws1.pane(for: ws1.activePaneID)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!

        let tab = pane1.extractTab(at: 0)!
        pane2.insertTab(tab, at: 0)

        XCTAssertEqual(pane1.tabs.count, 1)
    }

    func testMovingLastTabToWorkspaceLeavesPaneEmpty() {
        let ws1 = Workspace(folderPath: "/source")
        let ws2 = Workspace(folderPath: "/dest")

        let pane1 = ws1.pane(for: ws1.activePaneID)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!

        let tab = pane1.extractTab(at: 0)!
        pane2.insertTab(tab, at: 0)

        XCTAssertTrue(pane1.tabs.isEmpty)
        // Source workspace total tabs now 0 → would trigger workspace close
        let sourceTotalTabs = ws1.panes.values.reduce(0) { $0 + $1.tabs.count }
        XCTAssertEqual(sourceTotalTabs, 0)
    }

    func testMoveTabToWorkspaceAtInsertIndexBecomesActive() {
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let pane1 = ws1.pane(for: ws1.activePaneID)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!
        _ = pane2.addTab(workingDirectory: "/existing2")  // pane2 now has 2 tabs

        let tab = pane1.extractTab(at: 0)!
        let insertIndex = pane2.tabs.count  // append at end
        pane2.insertTab(tab, at: insertIndex)

        // insertTab sets activeTabIndex = insertIndex
        XCTAssertEqual(pane2.activeTabIndex, insertIndex)
        XCTAssertEqual(pane2.activeTab?.workingDirectory, "/a")
    }
}
