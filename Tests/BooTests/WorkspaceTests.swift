import XCTest

@testable import Boo

final class WorkspaceTests: XCTestCase {

    func testInit() {
        let ws = Workspace(folderPath: "/Users/test")
        XCTAssertEqual(ws.folderPath, "/Users/test")
        XCTAssertEqual(ws.displayName, "test")
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNotNil(ws.pane(for: ws.activePaneID))
    }

    func testCustomName() {
        let ws = Workspace(folderPath: "/Users/test")
        XCTAssertEqual(ws.displayName, "test")
        ws.customName = "My Workspace"
        XCTAssertEqual(ws.displayName, "My Workspace")
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

    func testResolvedColorPreset() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertNil(ws.resolvedColor)  // No color set
        ws.color = .blue
        XCTAssertNotNil(ws.resolvedColor)
        XCTAssertEqual(ws.resolvedColor, WorkspaceColor.blue.nsColor)
    }

    func testResolvedColorCustomOverridesPreset() {
        let ws = Workspace(folderPath: "/tmp")
        ws.color = .blue
        let custom = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        ws.customColor = custom
        XCTAssertEqual(ws.resolvedColor, custom)  // Custom takes precedence
    }

    func testResolvedColorCustomAlone() {
        let ws = Workspace(folderPath: "/tmp")
        let custom = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ws.customColor = custom
        XCTAssertEqual(ws.resolvedColor, custom)
    }

    func testResolvedColorClearCustom() {
        let ws = Workspace(folderPath: "/tmp")
        ws.customColor = NSColor.red
        ws.customColor = nil
        ws.color = .green
        XCTAssertEqual(ws.resolvedColor, WorkspaceColor.green.nsColor)
    }

    func testNormalizePaneStateRestoresFallbackTabForEmptyLeafPane() {
        let ws = Workspace(folderPath: "/tmp")
        let secondID = ws.splitPane(ws.activePaneID, direction: .horizontal)
        let pane = ws.pane(for: secondID)!

        _ = pane.extractTab(at: 0)
        XCTAssertTrue(pane.tabs.isEmpty)

        ws.normalizePaneState()

        XCTAssertEqual(ws.pane(for: secondID)?.tabs.count, 1)
        XCTAssertEqual(ws.pane(for: secondID)?.activeTab?.workingDirectory, "/tmp")
    }

    func testNormalizePaneStateRecreatesMissingLeafPane() {
        let rootID = UUID()
        let secondID = UUID()
        let ws = Workspace(
            folderPath: "/tmp",
            id: UUID(),
            splitTree: .split(
                direction: .horizontal,
                first: .leaf(id: rootID),
                second: .leaf(id: secondID),
                ratio: 0.5
            ),
            activePaneID: rootID
        )

        let rootPane = Pane(id: rootID)
        _ = rootPane.addTab(workingDirectory: "/tmp/root")
        ws.restorePane(rootPane)

        ws.normalizePaneState()

        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.pane(for: secondID)?.tabs.count, 1)
        XCTAssertEqual(ws.pane(for: secondID)?.activeTab?.workingDirectory, "/tmp")
    }

    func testRestorePaneRejectsPaneOutsideSplitTree() {
        let ws = Workspace(folderPath: "/tmp")
        let foreignPaneID = UUID()
        let foreignPane = Pane(id: foreignPaneID)
        _ = foreignPane.addTab(workingDirectory: "/tmp/foreign")

        XCTAssertFalse(ws.restorePane(foreignPane))
        XCTAssertNil(ws.pane(for: foreignPaneID))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.splitTree.leafIDs, [ws.activePaneID])
    }
}
