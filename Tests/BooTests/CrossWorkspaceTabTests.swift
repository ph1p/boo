import XCTest

@testable import Boo

/// Tests for cross-workspace tab move logic at the model level:
/// - detecting the "only tab in workspace" condition
/// - total tab count across multi-pane workspaces
/// - workspace state after a simulated tab transfer
/// - AppState integrity after workspace removal from a move
final class CrossWorkspaceTabTests: XCTestCase {

    // MARK: - Only-tab-in-workspace detection

    func testSinglePaneSingleTabIsOnlyTab() {
        let ws = Workspace(folderPath: "/tmp")
        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        XCTAssertEqual(totalTabs, 1)
    }

    func testSinglePaneMultipleTabsIsNotOnlyTab() {
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        _ = pane.addTab(workingDirectory: "/b")
        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        XCTAssertEqual(totalTabs, 2)
    }

    func testMultiPaneWorkspaceTabCount() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        let pane2 = ws.pane(for: id2)!
        _ = pane2.addTab(workingDirectory: "/b")

        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        // pane1: 1 tab (from init), pane2: 2 tabs (1 from split + 1 added)
        XCTAssertEqual(totalTabs, 3)
    }

    func testOnlyTabAcrossMultiPaneWorkspaceIsFalse() {
        let ws = Workspace(folderPath: "/tmp")
        let id2 = ws.splitPane(ws.activePaneID, direction: .horizontal)
        _ = id2  // keep both panes

        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        // Two panes each with 1 tab
        XCTAssertEqual(totalTabs, 2)
        XCTAssertFalse(totalTabs == 1, "Multi-pane workspace is not 'only tab'")
    }

    func testIsOnlyPaneWhenWorkspaceHasOnePanе() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertEqual(ws.panes.count, 1)
    }

    func testIsNotOnlyPaneWhenWorkspaceHasMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        _ = ws.splitPane(ws.activePaneID, direction: .horizontal)
        XCTAssertEqual(ws.panes.count, 2)
    }

    // MARK: - Simulated cross-workspace tab transfer (model layer)

    func testTransferTabToOtherWorkspaceModel() {
        let sourceWS = Workspace(folderPath: "/source")
        let destWS = Workspace(folderPath: "/dest")

        let sourcePaneID = sourceWS.activePaneID
        let sourcePane = sourceWS.pane(for: sourcePaneID)!
        _ = sourcePane.addTab(workingDirectory: "/extra")  // 2 tabs now

        let destPaneID = destWS.activePaneID
        let destPane = destWS.pane(for: destPaneID)!

        // Extract tab 0 from source and insert into dest
        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: destPane.tabs.count)

        XCTAssertEqual(sourcePane.tabs.count, 1)
        XCTAssertEqual(destPane.tabs.count, 2)
    }

    func testTransferLastTabLeavesSourcePaneEmpty() {
        let sourceWS = Workspace(folderPath: "/source")
        let destWS = Workspace(folderPath: "/dest")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        let destPane = destWS.pane(for: destWS.activePaneID)!

        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: 0)

        XCTAssertTrue(sourcePane.tabs.isEmpty)
        XCTAssertEqual(destPane.tabs.count, 2)
    }

    func testTransferPreservesTabWorkingDirectory() {
        let sourceWS = Workspace(folderPath: "/project")
        let destWS = Workspace(folderPath: "/other")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        let destPane = destWS.pane(for: destWS.activePaneID)!

        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: destPane.tabs.count)

        XCTAssertEqual(destPane.tabs.last?.workingDirectory, "/project")
    }

    func testTransferPreservesTabTitle() {
        let sourceWS = Workspace(folderPath: "/tmp")
        let destWS = Workspace(folderPath: "/other")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        sourcePane.updateTitle(at: 0, "nvim")

        let tab = sourcePane.extractTab(at: 0)!
        let destPane = destWS.pane(for: destWS.activePaneID)!
        destPane.insertTab(tab, at: 0)

        XCTAssertEqual(destPane.tabs[0].title, "nvim")
    }

    // MARK: - AppState after workspace closure

    func testRemoveWorkspaceAfterTransfer() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        XCTAssertEqual(state.workspaces.count, 2)

        // Simulate: transfer last tab from ws1 to ws2, then close ws1
        let pane1 = ws1.pane(for: ws1.activePaneID)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!
        let tab = pane1.extractTab(at: 0)!
        pane2.insertTab(tab, at: pane2.tabs.count)

        state.removeWorkspace(at: 0)

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.workspaces[0].folderPath, "/b")
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testActiveIndexAdjustsAfterSourceWorkspaceRemoved() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.addWorkspace(Workspace(folderPath: "/c"))
        state.setActiveWorkspace(2)  // active = /c

        // Remove /a (index 0) — active should shift to follow /c
        state.removeWorkspace(at: 0)

        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(state.activeWorkspaceIndex, 1)  // /c is now at index 1
        XCTAssertEqual(state.activeWorkspace?.folderPath, "/c")
    }

    func testDestinationWorkspaceReceivedTabAfterTransfer() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        let pane1 = ws1.pane(for: ws1.activePaneID)!
        _ = pane1.addTab(workingDirectory: "/extra")  // now 2 tabs

        let tab = pane1.extractTab(at: 0)!
        let pane2 = ws2.pane(for: ws2.activePaneID)!
        pane2.insertTab(tab, at: 0)

        let destWS = state.workspaces.first(where: { $0.folderPath == "/b" })!
        let destPane = destWS.pane(for: destWS.activePaneID)!
        XCTAssertEqual(destPane.tabs.count, 2)
    }

    // MARK: - paneViewWorkspaceNames logic (model-level simulation)

    func testOtherWorkspacesExcludeSourceWorkspace() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws3 = Workspace(folderPath: "/c")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(ws3)

        // Simulate paneViewWorkspaceNames for a pane in ws1
        let paneID = ws1.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })
        XCTAssertNotNil(sourceWS)
        XCTAssertEqual(sourceWS?.folderPath, "/a")

        let others = state.workspaces.enumerated().compactMap { (i, ws) -> (index: Int, name: String)? in
            ws.id == sourceWS?.id ? nil : (index: i, name: ws.displayName)
        }
        XCTAssertEqual(others.count, 2)
        XCTAssertFalse(others.contains(where: { $0.name == "a" }))
        XCTAssertTrue(others.contains(where: { $0.name == "b" }))
        XCTAssertTrue(others.contains(where: { $0.name == "c" }))
    }

    func testOtherWorkspacesEmptyWhenOnlyOneWorkspace() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        state.addWorkspace(ws1)

        let paneID = ws1.activePaneID
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })

        let others = state.workspaces.enumerated().compactMap { (i, ws) -> (index: Int, name: String)? in
            ws.id == sourceWS?.id ? nil : (index: i, name: ws.displayName)
        }
        XCTAssertTrue(others.isEmpty)
    }

    func testOtherWorkspacesIndexesAreCorrect() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws3 = Workspace(folderPath: "/c")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(ws3)

        let paneID = ws2.activePaneID  // source is ws2 (index 1)
        let sourceWS = state.workspaces.first(where: { $0.panes[paneID] != nil })

        let others = state.workspaces.enumerated().compactMap { (i, ws) -> (index: Int, name: String)? in
            ws.id == sourceWS?.id ? nil : (index: i, name: ws.displayName)
        }
        XCTAssertEqual(others.count, 2)
        XCTAssertTrue(others.contains(where: { $0.index == 0 && $0.name == "a" }))
        XCTAssertTrue(others.contains(where: { $0.index == 2 && $0.name == "c" }))
    }

    // MARK: - Drag abort: same-workspace last-tab guard

    func testSameWorkspaceLastTabDropShouldBeAborted() {
        // Simulate the condition that triggers the silent abort in handleTabDrop:
        // source and dest are in the same workspace, total tabs == 1.
        let ws = Workspace(folderPath: "/tmp")

        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        // In the real code the abort fires when: totalTabs == 1 AND source.paneID != dest.paneID.
        // Here we verify only the count half of that condition.
        XCTAssertEqual(totalTabs, 1)
    }

    func testSameWorkspaceMultiTabNeverAborts() {
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        _ = pane.addTab(workingDirectory: "/b")

        let totalTabs = ws.panes.values.reduce(0) { $0 + $1.tabs.count }
        XCTAssertGreaterThan(totalTabs, 1, "Should not abort when workspace has multiple tabs")
    }

    // MARK: - Cross-workspace last-tab condition

    func testCrossWorkspaceLastTabConditionDetected() {
        let sourceWS = Workspace(folderPath: "/source")
        // Only 1 pane with 1 tab (default state)
        let isLastTab = sourceWS.panes.values.reduce(0) { $0 + $1.tabs.count } == 1
        XCTAssertTrue(isLastTab)
    }

    func testCrossWorkspaceNotLastTabWhenMultipleTabs() {
        let sourceWS = Workspace(folderPath: "/source")
        let pane = sourceWS.pane(for: sourceWS.activePaneID)!
        _ = pane.addTab(workingDirectory: "/extra")

        let isLastTab = sourceWS.panes.values.reduce(0) { $0 + $1.tabs.count } == 1
        XCTAssertFalse(isLastTab)
    }

    func testCrossWorkspaceNotLastTabWhenMultiplePanes() {
        let sourceWS = Workspace(folderPath: "/source")
        _ = sourceWS.splitPane(sourceWS.activePaneID, direction: .horizontal)

        let isLastTab = sourceWS.panes.values.reduce(0) { $0 + $1.tabs.count } == 1
        XCTAssertFalse(isLastTab, "Two panes each with 1 tab = 2 total, not last tab")
    }
}
