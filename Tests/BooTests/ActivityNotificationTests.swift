import XCTest

@testable import Boo

/// Tests for the command-end activity notification system.
///
/// Design mirrors cmux TerminalNotificationStore:
/// - Suppress when isAppFocused && isFocusedPanel (the exact tab is visible and app is key)
/// - Set activity in all other cases (background workspace, background tab, app not focused)
/// - Clear on focus (didFocus / activateTab), NOT on workspace switch
final class ActivityNotificationTests: XCTestCase {

    // MARK: - Pane.setActivity

    func testSetActivityMarksTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/")
        pane.setActivity(true, at: 0)
        XCTAssertTrue(pane.tabs[0].state.hasActivity)
    }

    func testSetActivityClearsTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/")
        pane.setActivity(true, at: 0)
        pane.setActivity(false, at: 0)
        XCTAssertFalse(pane.tabs[0].state.hasActivity)
    }

    func testSetActivityOutOfBoundsIsNoop() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/")
        pane.setActivity(true, at: 99)
        XCTAssertFalse(pane.tabs[0].state.hasActivity)
    }

    func testSetActivityOnlyAffectsTargetTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActivity(true, at: 1)
        XCTAssertFalse(pane.tabs[0].state.hasActivity)
        XCTAssertTrue(pane.tabs[1].state.hasActivity)
        XCTAssertFalse(pane.tabs[2].state.hasActivity)
    }

    // MARK: - Clear on tab focus (mirrors cmux markRead on surfaceDidBecomeActive)

    func testActivateTabDoesNotClearOtherTabs() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActivity(true, at: 0)
        pane.setActivity(true, at: 2)

        pane.setActivity(false, at: 1)
        pane.setActiveTab(1)

        XCTAssertTrue(pane.tabs[0].state.hasActivity)
        XCTAssertFalse(pane.tabs[1].state.hasActivity)
        XCTAssertTrue(pane.tabs[2].state.hasActivity)
    }

    // MARK: - Workspace.hasActivity

    func testWorkspaceHasActivityFalseByDefault() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertFalse(ws.hasActivity)
    }

    func testWorkspaceHasActivityTrueWhenTabHasActivity() {
        let ws = Workspace(folderPath: "/tmp")
        guard let pane = ws.pane(for: ws.activePaneID) else { return XCTFail("No pane") }
        pane.setActivity(true, at: pane.activeTabIndex)
        XCTAssertTrue(ws.hasActivity)
    }

    func testWorkspaceHasActivityFalseAfterClear() {
        let ws = Workspace(folderPath: "/tmp")
        guard let pane = ws.pane(for: ws.activePaneID) else { return XCTFail("No pane") }
        pane.setActivity(true, at: pane.activeTabIndex)
        pane.setActivity(false, at: pane.activeTabIndex)
        XCTAssertFalse(ws.hasActivity)
    }

    func testWorkspaceHasActivityAcrossMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        ws.splitPane(ws.activePaneID, direction: .horizontal)
        let paneIDs = Array(ws.panes.keys)
        XCTAssertEqual(paneIDs.count, 2)
        ws.panes[paneIDs[1]]?.setActivity(true, at: 0)
        XCTAssertTrue(ws.hasActivity)
    }

    func testWorkspaceHasActivityFalseWhenAllPanesCleared() {
        let ws = Workspace(folderPath: "/tmp")
        ws.splitPane(ws.activePaneID, direction: .horizontal)
        let panes = Array(ws.panes.values)
        for pane in panes { pane.setActivity(true, at: 0) }
        XCTAssertTrue(ws.hasActivity)
        for pane in panes { pane.setActivity(false, at: 0) }
        XCTAssertFalse(ws.hasActivity)
    }
}
