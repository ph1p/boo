import XCTest
@testable import Exterm

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
        XCTAssertEqual(state.activeWorkspaceIndex, 1) // Last added
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
        XCTAssertEqual(state.activeWorkspaceIndex, 0) // Unchanged
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
        state.removeWorkspace(at: 1) // Remove active
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    func testNoActiveWorkspace() {
        let state = AppState()
        XCTAssertNil(state.activeWorkspace)
        XCTAssertEqual(state.activeWorkspaceIndex, -1)
    }
}
