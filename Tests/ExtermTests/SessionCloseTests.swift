import XCTest
@testable import Exterm

final class SessionCloseTests: XCTestCase {

    // MARK: - Pane close behavior (mirrors smartCloseAction logic)

    func testSingleTabPaneCloseRemovesTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        XCTAssertEqual(pane.tabs.count, 1)

        pane.removeTab(at: 0)
        XCTAssertTrue(pane.tabs.isEmpty)
        XCTAssertEqual(pane.activeTabIndex, -1)
    }

    func testMultiTabPaneCloseRemovesOnlyActiveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        XCTAssertEqual(pane.activeTabIndex, 2)

        // Remove the active tab (index 2, "/c")
        pane.removeTab(at: pane.activeTabIndex)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/a")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/b")
    }

    func testClosePaneInSplitWorkspace() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)
        XCTAssertEqual(ws.panes.count, 2)

        let closed = ws.closePane(newID)
        XCTAssertTrue(closed)
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertNotNil(ws.pane(for: originalID))
    }

    func testCloseLastPaneReturnsFalse() {
        let ws = Workspace(folderPath: "/tmp")
        let closed = ws.closePane(ws.activePaneID)
        XCTAssertFalse(closed)
    }

    func testActivePaneSwitchesOnClose() {
        let ws = Workspace(folderPath: "/tmp")
        let firstID = ws.activePaneID
        let secondID = ws.splitPane(firstID, direction: .horizontal)
        ws.activePaneID = secondID

        let closed = ws.closePane(secondID)
        XCTAssertTrue(closed)
        XCTAssertEqual(ws.activePaneID, firstID)
    }

    // MARK: - Smart close priority

    func testSmartCloseWithMultipleTabs() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        pane.removeTab(at: pane.activeTabIndex)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/a")
    }

    func testSmartCloseWithSingleTabMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        let firstID = ws.activePaneID
        let secondID = ws.splitPane(firstID, direction: .vertical)

        ws.activePaneID = secondID
        let closed = ws.closePane(secondID)
        XCTAssertTrue(closed)
        XCTAssertEqual(ws.panes.count, 1)
    }

    // MARK: - Exit callback wiring

    func testPTYExitCallbackDirect() {
        var exitCalled = false
        let pty = PTYProcess()
        pty.onExited = { exitCalled = true }

        pty.onExited?()
        XCTAssertTrue(exitCalled)
    }

    func testExitCallbackChainPTYToSession() {
        var sessionEnded = false

        let pty = PTYProcess()
        pty.onExited = {
            sessionEnded = true
        }

        pty.onExited?()
        XCTAssertTrue(sessionEnded)
    }

    func testRemoveMiddleTabKeepsOthers() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")

        pane.removeTab(at: 1)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/a")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/c")
    }

    func testRemoveFirstTabKeepsOthers() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.setActiveTab(0)

        pane.removeTab(at: 0)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/b")
    }
}
