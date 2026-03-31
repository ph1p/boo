import XCTest

@testable import Boo

final class WorkspaceSwitchTests: XCTestCase {

    func testWorkspaceCreation() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNotNil(ws.pane(for: ws.activePaneID))
        XCTAssertEqual(ws.pane(for: ws.activePaneID)?.activeTab?.workingDirectory, "/tmp")
    }

    func testWorkspaceSplitPreservesOriginal() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)

        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertNotNil(ws.pane(for: originalID), "Original pane should still exist")
        XCTAssertNotNil(ws.pane(for: newID), "New pane should exist")
        XCTAssertEqual(ws.splitTree.leafIDs.count, 2)
    }

    func testWorkspaceSplitVertical() {
        let ws = Workspace(folderPath: "/home")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .vertical)

        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 2)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(originalID))
        XCTAssertTrue(ws.splitTree.leafIDs.contains(newID))
    }

    func testCloseOneOfTwoPanes() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)

        XCTAssertTrue(ws.closePane(newID))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNotNil(ws.pane(for: originalID))
        XCTAssertNil(ws.pane(for: newID))
        XCTAssertEqual(ws.splitTree.leafIDs.count, 1)
    }

    func testCloseLastPaneFails() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertFalse(ws.closePane(ws.activePaneID))
        XCTAssertEqual(ws.panes.count, 1)
    }

    func testActivePaneSwitchesOnClose() {
        let ws = Workspace(folderPath: "/tmp")
        let firstID = ws.activePaneID
        let secondID = ws.splitPane(firstID, direction: .horizontal)
        ws.activePaneID = secondID

        XCTAssertTrue(ws.closePane(secondID))
        XCTAssertEqual(ws.activePaneID, firstID)
    }

    func testMultipleSplits() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        XCTAssertEqual(ws.panes.count, 3)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 3)

        // Close middle pane
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 2)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id1))
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id3))
    }

    func testAppStateWorkspaceSwitching() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        XCTAssertEqual(state.activeWorkspaceIndex, 1)

        state.setActiveWorkspace(0)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
        XCTAssertTrue(state.activeWorkspace === ws1)

        state.setActiveWorkspace(1)
        XCTAssertEqual(state.activeWorkspaceIndex, 1)
        XCTAssertTrue(state.activeWorkspace === ws2)
    }

    func testWorkspacePanesPreservedAcrossSwitch() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")

        // Split ws1
        let ws1_pane1 = ws1.activePaneID
        let ws1_pane2 = ws1.splitPane(ws1_pane1, direction: .horizontal)

        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        // Switch to ws1
        state.setActiveWorkspace(0)
        XCTAssertEqual(state.activeWorkspace?.panes.count, 2)
        XCTAssertEqual(state.activeWorkspace?.splitTree.leafIDs.count, 2)

        // Switch to ws2
        state.setActiveWorkspace(1)
        XCTAssertEqual(state.activeWorkspace?.panes.count, 1)

        // Switch back to ws1 — panes should still be there
        state.setActiveWorkspace(0)
        XCTAssertEqual(state.activeWorkspace?.panes.count, 2)
        XCTAssertNotNil(state.activeWorkspace?.pane(for: ws1_pane1))
        XCTAssertNotNil(state.activeWorkspace?.pane(for: ws1_pane2))
    }

    func testSplitTreeAfterClosingPane() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        // Tree should be split with two leaves
        XCTAssertEqual(ws.splitTree.leafIDs, [id1, id2])

        // Close id2
        XCTAssertTrue(ws.closePane(id2))

        // Tree should be back to single leaf
        XCTAssertEqual(ws.splitTree.leafIDs, [id1])
    }

    func testPaneTabManagement() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabIndex, 1)

        pane.setActiveTab(0)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/a")

        pane.removeTab(at: 1)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/a")
    }

    func testGhosttyViewCallbacksWired() {
        // Verify GhosttyView has the expected callback properties
        let gv = GhosttyView(workingDirectory: "/tmp")
        defer { gv.destroy() }

        XCTAssertNil(gv.onFocused)
        XCTAssertNil(gv.onPwdChanged)
        XCTAssertNil(gv.onTitleChanged)
        XCTAssertNil(gv.onProcessExited)

        // Wire callbacks
        gv.onFocused = {}
        gv.onPwdChanged = { _ in }

        XCTAssertNotNil(gv.onFocused)
        XCTAssertNotNil(gv.onPwdChanged)
    }

    func testClosePaneFocusesClosestSibling() {
        // Layout: id1 | (id2 / id3)  — closing id2 should focus id3 (sibling), not id1
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)
        ws.activePaneID = id2

        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.activePaneID, id3, "Should focus closest sibling id3, not id1")
    }

    func testClosePaneFocusesSiblingInSimpleSplit() {
        // Layout: id1 | id2 — closing id1 should focus id2
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id1

        XCTAssertTrue(ws.closePane(id1))
        XCTAssertEqual(ws.activePaneID, id2)
    }

    func testSplitDirectionDetection() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        // Verify the tree structure
        if case .split(let dir, let first, let second, let ratio) = splitTree {
            XCTAssertEqual(dir, .horizontal)
            XCTAssertEqual(first.leafIDs, [id1])
            XCTAssertEqual(second.leafIDs, [id2])
            XCTAssertEqual(ratio, 0.5)
        } else {
            XCTFail("Expected split tree")
        }
    }
}
