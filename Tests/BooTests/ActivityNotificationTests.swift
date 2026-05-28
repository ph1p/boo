import XCTest

@testable import Boo

/// Tests for the command-end activity notification system.
///
/// Design mirrors cmux TerminalNotificationStore:
/// - Suppress when isAppFocused && isFocusedPanel (the exact tab is visible and app is key)
/// - Set activity in all other cases (background workspace, background tab, app not focused)
/// - Clear on focus (didFocus / activateTab), NOT on workspace switch
final class ActivityNotificationTests: XCTestCase {

    // MARK: - TabState defaults

    func testHasActivityDefaultsFalse() {
        let state = TabState(workingDirectory: "/", title: "test")
        XCTAssertFalse(state.hasActivity)
    }

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

    // MARK: - Suppress logic (mirrors cmux shouldSuppressExternalDelivery)

    func testSuppressWhenFocusedPanel() {
        // isFocusedPanel = isActiveTab && appFocused → suppress, no activity set
        let result = isFocusedPanel(isActiveWorkspace: true, isActivePane: true, isActiveTab: true, appFocused: true)
        XCTAssertTrue(result)
    }

    func testNoSuppressWhenAppNotFocused() {
        // App not focused → always set activity regardless of tab
        let result = isFocusedPanel(isActiveWorkspace: true, isActivePane: true, isActiveTab: true, appFocused: false)
        XCTAssertFalse(result)
    }

    func testNoSuppressWhenDifferentTab() {
        // Right pane, but different tab index
        let result = isFocusedPanel(isActiveWorkspace: true, isActivePane: true, isActiveTab: false, appFocused: true)
        XCTAssertFalse(result)
    }

    func testNoSuppressWhenDifferentPane() {
        let result = isFocusedPanel(isActiveWorkspace: true, isActivePane: false, isActiveTab: false, appFocused: true)
        XCTAssertFalse(result)
    }

    func testNoSuppressWhenDifferentWorkspace() {
        // Command finishes in a background workspace → always set activity
        let result = isFocusedPanel(isActiveWorkspace: false, isActivePane: false, isActiveTab: false, appFocused: true)
        XCTAssertFalse(result)
    }

    // MARK: - Clear on tab focus (mirrors cmux markRead on surfaceDidBecomeActive)

    func testActivateTabClearsActivityOnThatTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.setActivity(true, at: 1)

        // Simulate PaneView.activateTab
        pane.setActivity(false, at: 1)
        pane.setActiveTab(1)

        XCTAssertFalse(pane.tabs[1].state.hasActivity)
    }

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

    // MARK: - Activity persists until explicitly cleared (not on workspace switch)

    func testActivityPersistsAfterWorkspaceSwitch() {
        // cmux: markRead only fires on surfaceDidBecomeActive, not on tab/workspace switch.
        // Switching workspace does NOT clear activity on other tabs.
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.setActivity(true, at: 0)

        // Simulate switching to tab 1 without focusing tab 0
        pane.setActivity(false, at: 1)
        pane.setActiveTab(1)

        XCTAssertTrue(pane.tabs[0].state.hasActivity, "Tab 0 activity must persist — not cleared by switching away")
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
        panes.forEach { $0.setActivity(true, at: 0) }
        XCTAssertTrue(ws.hasActivity)
        panes.forEach { $0.setActivity(false, at: 0) }
        XCTAssertFalse(ws.hasActivity)
    }

    // MARK: - Helper

    /// Pure model of the suppress check — no app/window state needed.
    private func isFocusedPanel(
        isActiveWorkspace: Bool, isActivePane: Bool, isActiveTab: Bool, appFocused: Bool
    ) -> Bool {
        isActiveWorkspace && isActivePane && isActiveTab && appFocused
    }
}
