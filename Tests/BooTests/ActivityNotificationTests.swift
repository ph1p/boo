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
        for pane in panes { pane.setActivity(true, at: 0) }
        XCTAssertTrue(ws.hasActivity)
        for pane in panes { pane.setActivity(false, at: 0) }
        XCTAssertFalse(ws.hasActivity)
    }

    // MARK: - Bell / desktop notification setActivity

    func testBellSetsActivityOnActiveTab() {
        // Bell handler calls setActivity(true, at: activeTabIndex) — verify model update.
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        // Active tab is index 1 after two adds.
        pane.setActivity(true, at: pane.activeTabIndex)
        XCTAssertTrue(pane.tabs[pane.activeTabIndex].state.hasActivity)
    }

    func testDesktopNotificationSetsActivityOnActiveTab() {
        // Desktop notification handler also calls setActivity(true, at: activeTabIndex).
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        pane.setActivity(true, at: pane.activeTabIndex)
        XCTAssertTrue(pane.tabs[0].state.hasActivity)
        // Clearing works the same as for command-end.
        pane.setActivity(false, at: pane.activeTabIndex)
        XCTAssertFalse(pane.tabs[0].state.hasActivity)
    }

    // MARK: - Tab attribution via tabID

    /// Verify that activity is attributed to the correct (non-active) tab when the
    /// event carries that tab's UUID — mirrors the tabID-resolution path added in the
    /// commandEnded / bellRangIn / desktopNotification handlers.
    func testActivityLandsOnTabMatchingTabID() {
        let pane = Pane()
        pane.addTab(workingDirectory: "/a")
        pane.addTab(workingDirectory: "/b")
        pane.addTab(workingDirectory: "/c")
        XCTAssertEqual(pane.tabs.count, 3)

        // Active tab after three adds is index 2 (last added).
        XCTAssertEqual(pane.activeTabIndex, 2)

        // Capture the UUID of tab 1 (a background tab).
        let targetTabID = pane.tabs[1].id

        // Simulate the tabID-resolution path used by commandEnded / bellRangIn / desktopNotification:
        // resolve index from the carried UUID, fall back to activeTabIndex when nil/not found.
        let resolvedIndex = pane.tabs.firstIndex { $0.id == targetTabID } ?? pane.activeTabIndex
        pane.setActivity(true, at: resolvedIndex)

        // Activity must land on tab 1 (the event source), not tab 2 (the currently active tab).
        XCTAssertFalse(pane.tabs[0].state.hasActivity, "tab 0 must be untouched")
        XCTAssertTrue(pane.tabs[1].state.hasActivity, "tab 1 (event source) must have activity")
        XCTAssertFalse(pane.tabs[2].state.hasActivity, "tab 2 (active) must not receive a background tab's event")
    }

    // MARK: - Helper

    /// Pure model of the suppress check — no app/window state needed.
    private func isFocusedPanel(
        isActiveWorkspace: Bool, isActivePane: Bool, isActiveTab: Bool, appFocused: Bool
    ) -> Bool {
        isActiveWorkspace && isActivePane && isActiveTab && appFocused
    }
}
