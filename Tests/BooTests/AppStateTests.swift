import XCTest

@testable import Boo

final class AppStateTests: XCTestCase {

    func testAddWorkspace() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        state.addWorkspace(ws)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
        XCTAssertTrue(state.activeWorkspace === ws)
    }

    func testMultipleWorkspaces() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(state.activeWorkspaceIndex, 1)  // Last added
    }

    func testSetActiveWorkspace() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.setActiveWorkspace(0)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testSetActiveWorkspaceOutOfBounds() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.setActiveWorkspace(5)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)  // Unchanged
    }

    func testRemoveWorkspace() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.removeWorkspace(at: 0)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testRemoveActiveWorkspace() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.removeWorkspace(at: 1)  // Remove active
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testNoActiveWorkspace() {
        let state = AppState()
        XCTAssertNil(state.activeWorkspace)
        XCTAssertEqual(state.activeWorkspaceIndex, -1)
    }

    // MARK: - moveWorkspace tests

    func testMoveWorkspaceForward() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.addWorkspace(Workspace(folderPath: "/c"))
        state.setActiveWorkspace(0)

        // Move /a from index 0 to after index 2
        state.moveWorkspace(from: 0, to: 3)
        XCTAssertEqual(state.workspaces[0].folderPath, "/b")
        XCTAssertEqual(state.workspaces[1].folderPath, "/c")
        XCTAssertEqual(state.workspaces[2].folderPath, "/a")
        XCTAssertEqual(state.activeWorkspaceIndex, 2)  // active followed the move
    }

    func testMoveWorkspaceBackward() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.addWorkspace(Workspace(folderPath: "/c"))
        state.setActiveWorkspace(1)

        // Move /c from index 2 to index 0
        state.moveWorkspace(from: 2, to: 0)
        XCTAssertEqual(state.workspaces[0].folderPath, "/c")
        XCTAssertEqual(state.workspaces[1].folderPath, "/a")
        XCTAssertEqual(state.workspaces[2].folderPath, "/b")
        XCTAssertEqual(state.activeWorkspaceIndex, 2)  // /b shifted right
    }

    func testMoveWorkspaceNoOp() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.setActiveWorkspace(0)

        state.moveWorkspace(from: 0, to: 0)
        XCTAssertEqual(state.workspaces[0].folderPath, "/a")
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testMoveWorkspaceActiveIndexTracking() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.addWorkspace(Workspace(folderPath: "/c"))
        state.setActiveWorkspace(2)  // active is /c

        // Move /a forward past active
        state.moveWorkspace(from: 0, to: 3)
        // /b is now 0, /c is now 1, /a is now 2
        XCTAssertEqual(state.activeWorkspaceIndex, 1)  // /c shifted left
    }

    func testMoveWorkspaceOutOfBounds() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.setActiveWorkspace(0)

        state.moveWorkspace(from: -1, to: 0)
        XCTAssertEqual(state.workspaces.count, 2)
        state.moveWorkspace(from: 5, to: 0)
        XCTAssertEqual(state.workspaces.count, 2)
    }

    func testWorkspaceContainingPaneReturnsCorrectWorkspace() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws2SecondPane = ws2.splitPane(ws2.activePaneID, direction: .horizontal)
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        XCTAssertTrue(state.workspaceContainingPane(ws1.activePaneID) === ws1)
        XCTAssertTrue(state.workspaceContainingPane(ws2SecondPane) === ws2)
        XCTAssertNil(state.workspaceContainingPane(UUID()))
    }

    func testIndexOfWorkspaceContainingPaneReturnsCorrectIndex() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws2SecondPane = ws2.splitPane(ws2.activePaneID, direction: .vertical)
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        XCTAssertEqual(state.indexOfWorkspace(containingPane: ws1.activePaneID), 0)
        XCTAssertEqual(state.indexOfWorkspace(containingPane: ws2SecondPane), 1)
        XCTAssertNil(state.indexOfWorkspace(containingPane: UUID()))
    }

    func testEnsureUniquePaneIDsAcrossWorkspacesRemapsConflictsAndPreservesState() {
        let sharedPaneID = UUID()

        let ws1 = Workspace(
            folderPath: "/a",
            id: UUID(),
            splitTree: .leaf(id: sharedPaneID),
            activePaneID: sharedPaneID
        )
        let ws1Pane = Pane(id: sharedPaneID)
        _ = ws1Pane.addTab(workingDirectory: "/a")
        XCTAssertTrue(ws1.restorePane(ws1Pane))

        let ws2 = Workspace(
            folderPath: "/b",
            id: UUID(),
            splitTree: .leaf(id: sharedPaneID),
            activePaneID: sharedPaneID
        )
        let ws2Pane = Pane(id: sharedPaneID)
        _ = ws2Pane.addTab(workingDirectory: "/b")
        _ = ws2Pane.addTab(workingDirectory: "/b/second")
        XCTAssertTrue(ws2.restorePane(ws2Pane))

        let state = AppState()
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        state.ensureUniquePaneIDsAcrossWorkspaces()

        let ws1PaneIDs = Set(ws1.splitTree.leafIDs)
        let ws2PaneIDs = Set(ws2.splitTree.leafIDs)
        XCTAssertTrue(ws1PaneIDs.isDisjoint(with: ws2PaneIDs))
        XCTAssertEqual(ws1PaneIDs.count, 1)
        XCTAssertEqual(ws2PaneIDs.count, 1)
        XCTAssertEqual(ws2.totalTabCount, 2)
        XCTAssertNotEqual(ws2.activePaneID, sharedPaneID)
        XCTAssertNotNil(ws2.pane(for: ws2.activePaneID))
        XCTAssertNil(ws2.pane(for: sharedPaneID))
    }

    func testReplaceSplitTreeTargetsWorkspaceByIDNotActiveWorkspace() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        let ws1SecondPane = ws1.splitPane(ws1.activePaneID, direction: .horizontal)
        let ws1ThirdPane = ws1.splitPane(ws1SecondPane, direction: .vertical)

        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        XCTAssertTrue(state.activeWorkspace === ws2)

        let ws2OriginalLeafIDs = ws2.splitTree.leafIDs
        XCTAssertTrue(state.replaceSplitTree(for: ws1.id, with: ws1.splitTree))

        XCTAssertEqual(Set(ws1.splitTree.leafIDs), Set([ws1.activePaneID, ws1SecondPane, ws1ThirdPane]))
        XCTAssertEqual(ws2.splitTree.leafIDs, ws2OriginalLeafIDs)
        XCTAssertEqual(ws2.panes.count, 1)
    }

    func testWorkspaceDefaultSidebarStateUsesGlobalDefaultWidthSnapshot() {
        let originalWidth = AppSettings.shared.sidebarWidth
        let originalHidden = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarWidth = 286
        AppSettings.shared.sidebarDefaultHidden = false
        defer {
            AppSettings.shared.sidebarWidth = originalWidth
            AppSettings.shared.sidebarDefaultHidden = originalHidden
        }

        let workspace = Workspace(folderPath: "/tmp")

        XCTAssertEqual(workspace.sidebarState.width ?? -1, 286, accuracy: 0.1)
        XCTAssertEqual(workspace.sidebarState.isVisible, true)
    }

    func testNextGeneratedWorkspaceNameStartsAtOne() {
        let state = AppState()

        XCTAssertEqual(state.nextGeneratedWorkspaceName(), "Workspace 1")
    }

    func testNextGeneratedWorkspaceNameIncrementsFromExistingGeneratedNames() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        ws1.customName = "Workspace 1"
        let ws2 = Workspace(folderPath: "/b")
        ws2.customName = "Workspace 2"
        let renamed = Workspace(folderPath: "/c")
        renamed.customName = "My Project"

        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(renamed)

        XCTAssertEqual(state.nextGeneratedWorkspaceName(), "Workspace 4")
    }

    func testNextGeneratedWorkspaceNameUsesWorkspaceCountInsteadOfHighestExistingNumber() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        ws1.customName = "Workspace 1"
        let ws7 = Workspace(folderPath: "/b")
        ws7.customName = "Workspace 7"

        state.addWorkspace(ws1)
        state.addWorkspace(ws7)

        XCTAssertEqual(state.nextGeneratedWorkspaceName(), "Workspace 3")
    }
}
