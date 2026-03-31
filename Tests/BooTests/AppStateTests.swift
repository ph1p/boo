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
}
