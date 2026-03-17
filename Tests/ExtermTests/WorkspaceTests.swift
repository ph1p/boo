import XCTest
@testable import Exterm

final class WorkspaceTests: XCTestCase {

    func testInit() {
        let ws = Workspace(folderPath: "/Users/test")
        XCTAssertEqual(ws.folderPath, "/Users/test")
        XCTAssertEqual(ws.displayName, "test")
        XCTAssertEqual(ws.currentDirectory, "/Users/test")
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNotNil(ws.pane(for: ws.activePaneID))
    }

    func testCustomName() {
        let ws = Workspace(folderPath: "/Users/test")
        XCTAssertEqual(ws.displayName, "test")
        ws.customName = "My Workspace"
        XCTAssertEqual(ws.displayName, "My Workspace")
    }

    func testColor() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertEqual(ws.color, .none)
        ws.color = .blue
        XCTAssertEqual(ws.color, .blue)
        XCTAssertNotNil(ws.color.nsColor)
    }

    func testPin() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertFalse(ws.isPinned)
        ws.isPinned = true
        XCTAssertTrue(ws.isPinned)
    }

    func testSplitPane() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)

        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertNotNil(ws.pane(for: originalID))
        XCTAssertNotNil(ws.pane(for: newID))
        XCTAssertEqual(ws.splitTree.leafIDs.count, 2)
    }

    func testClosePane() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)

        XCTAssertTrue(ws.closePane(newID))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNil(ws.pane(for: newID))
        XCTAssertNotNil(ws.pane(for: originalID))
    }

    func testCloseLastPane() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertFalse(ws.closePane(ws.activePaneID))
    }

    func testHandleDirectoryChange() {
        let ws = Workspace(folderPath: "/tmp")
        var received: String?
        ws.onDirectoryChanged = { received = $0 }

        ws.handleDirectoryChange("/Users/test")
        XCTAssertEqual(ws.currentDirectory, "/Users/test")
        XCTAssertEqual(received, "/Users/test")
    }

    func testHandleDirectoryChangeNoOp() {
        let ws = Workspace(folderPath: "/tmp")
        var callCount = 0
        ws.onDirectoryChanged = { _ in callCount += 1 }

        ws.handleDirectoryChange("/tmp") // Same as current
        XCTAssertEqual(callCount, 0)
    }

    func testStopAll() {
        let ws = Workspace(folderPath: "/tmp")
        _ = ws.splitPane(ws.activePaneID, direction: .vertical)
        ws.stopAll()
        XCTAssertTrue(ws.panes.isEmpty)
    }

    func testWorkspaceColorAllCases() {
        XCTAssertEqual(WorkspaceColor.allCases.count, 8)
        XCTAssertNil(WorkspaceColor.none.nsColor)
        for color in WorkspaceColor.allCases where color != .none {
            XCTAssertNotNil(color.nsColor)
            XCTAssertFalse(color.label.isEmpty)
        }
    }
}
