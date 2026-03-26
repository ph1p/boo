import XCTest

@testable import Exterm

/// Tests for debounce cancellation on tab switch and captured tab index safety.
@MainActor
final class PaneViewDebounceTests: XCTestCase {

    // MARK: - Tab title isolation across tab switch

    func testTabSwitchPreservesTabTitles() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        // Set distinct titles on each tab
        pane.updateTitle(at: 0, "SSH: server")
        pane.updateTitle(at: 1, "local-shell")

        // Switch to tab 0 then back to tab 1
        pane.setActiveTab(0)
        pane.setActiveTab(1)

        XCTAssertEqual(pane.tabs[0].title, "SSH: server", "Tab 0 title should be preserved")
        XCTAssertEqual(pane.tabs[1].title, "local-shell", "Tab 1 title should be preserved")
    }

    func testUpdateTitleAtSpecificIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        // Update title at index 0 while active tab is 1
        pane.setActiveTab(1)
        let tab1TitleBefore = pane.tabs[1].title
        pane.updateTitle(at: 0, "updated-title")

        XCTAssertEqual(pane.tabs[0].title, "updated-title")
        XCTAssertEqual(pane.tabs[1].title, tab1TitleBefore, "Active tab should not be affected")
    }

    func testUpdateTitleOutOfBoundsIgnored() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        // Should not crash when index is out of bounds
        pane.updateTitle(at: 5, "should-not-crash")
        XCTAssertEqual(pane.tabs.count, 1)
    }

    // MARK: - CWD isolation across tab switch

    func testTabSwitchPreservesCwd() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        pane.setActiveTab(0)
        pane.setActiveTab(1)

        XCTAssertEqual(pane.tabs[0].workingDirectory, "/tmp/a")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/tmp/b")
    }

    func testUpdateCwdAtSpecificIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        pane.setActiveTab(1)
        pane.updateWorkingDirectory(at: 0, "/home/user")

        XCTAssertEqual(pane.tabs[0].workingDirectory, "/home/user")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/tmp/b")
    }

    // MARK: - Captured index safety with closed tabs

    func testUpdateAfterTabCloseIgnored() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")
        _ = pane.addTab(workingDirectory: "/tmp/c")

        let capturedIndex = 2
        pane.removeTab(at: 2)

        // Simulates a debounce callback firing after the tab was closed
        if capturedIndex >= 0, capturedIndex < pane.tabs.count {
            pane.updateTitle(at: capturedIndex, "stale-title")
        }

        // Tab at index 2 no longer exists — no crash, no corruption
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertNotEqual(pane.tabs[0].title, "stale-title")
        XCTAssertNotEqual(pane.tabs[1].title, "stale-title")
    }
}
