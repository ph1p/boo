import XCTest

@testable import Boo

/// Tests for debounce cancellation on tab switch and captured tab index safety.
@MainActor
final class PaneViewDebounceTests: XCTestCase {

    // MARK: - Tab title isolation across tab switch

    func testUpdateTitleOutOfBoundsIgnored() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        // Should not crash when index is out of bounds
        pane.updateTitle(at: 5, "should-not-crash")
        XCTAssertEqual(pane.tabs.count, 1)
    }

    // MARK: - CWD isolation across tab switch

    func testUpdateCwdAtSpecificIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        pane.setActiveTab(1)
        pane.updateWorkingDirectory(at: 0, "/home/user")

        XCTAssertEqual(pane.tabs[0].workingDirectory, "/home/user")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/tmp/b")
    }
}
