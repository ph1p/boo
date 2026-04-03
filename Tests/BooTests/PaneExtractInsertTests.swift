import XCTest

@testable import Boo

/// Tests for Pane.extractTab and Pane.insertTab, which back all cross-pane and
/// cross-workspace tab drag operations.
final class PaneExtractInsertTests: XCTestCase {

    // MARK: - extractTab

    func testExtractTabRemovesTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        let extracted = pane.extractTab(at: 0)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/b")
    }

    func testExtractTabReturnsCorrectTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")

        let extracted = pane.extractTab(at: 1)
        XCTAssertEqual(extracted?.workingDirectory, "/b")
    }

    func testExtractTabOutOfBoundsReturnsNil() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")

        XCTAssertNil(pane.extractTab(at: 5))
        XCTAssertNil(pane.extractTab(at: -1))
        XCTAssertEqual(pane.tabs.count, 1)
    }

    func testExtractLastTabLeavesEmptyPane() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")

        let extracted = pane.extractTab(at: 0)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(pane.tabs.isEmpty)
        XCTAssertEqual(pane.activeTabIndex, 0)  // clamped to 0 even when empty
    }

    func testExtractActiveTabAdjustsActiveIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActiveTab(1)  // active = /b

        _ = pane.extractTab(at: 1)  // remove active
        // Active should clamp to within new bounds and point at /c (now index 1)
        XCTAssertEqual(pane.activeTabIndex, 1)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/c")
    }

    func testExtractTabBeforeActiveDecrementsActiveIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActiveTab(2)  // active = /c at index 2

        _ = pane.extractTab(at: 0)  // remove /a (before active)
        // Active should now be index 1, still pointing at /c
        XCTAssertEqual(pane.activeTabIndex, 1)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/c")
    }

    func testExtractTabAfterActivePreservesActiveIndex() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActiveTab(0)  // active = /a at index 0

        _ = pane.extractTab(at: 2)  // remove /c (after active)
        XCTAssertEqual(pane.activeTabIndex, 0)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/a")
    }

    // MARK: - insertTab

    func testInsertTabAppendsAtEnd() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/a")
        dest.insertTab(tab, at: 1)

        XCTAssertEqual(dest.tabs.count, 2)
        XCTAssertEqual(dest.tabs[1].workingDirectory, "/x")
        XCTAssertEqual(dest.activeTabIndex, 1)
    }

    func testInsertTabAtBeginning() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/a")
        _ = dest.addTab(workingDirectory: "/b")
        dest.insertTab(tab, at: 0)

        XCTAssertEqual(dest.tabs[0].workingDirectory, "/x")
        XCTAssertEqual(dest.activeTabIndex, 0)
    }

    func testInsertTabInMiddle() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/a")
        _ = dest.addTab(workingDirectory: "/b")
        _ = dest.addTab(workingDirectory: "/c")
        dest.insertTab(tab, at: 1)

        XCTAssertEqual(dest.tabs.count, 4)
        XCTAssertEqual(dest.tabs[1].workingDirectory, "/x")
        XCTAssertEqual(dest.activeTabIndex, 1)
    }

    func testInsertTabClampsNegativeIndex() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/a")
        dest.insertTab(tab, at: -10)

        XCTAssertEqual(dest.tabs[0].workingDirectory, "/x")
        XCTAssertEqual(dest.activeTabIndex, 0)
    }

    func testInsertTabClampsOverflowIndex() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/a")
        dest.insertTab(tab, at: 999)

        XCTAssertEqual(dest.tabs.count, 2)
        XCTAssertEqual(dest.tabs[1].workingDirectory, "/x")
        XCTAssertEqual(dest.activeTabIndex, 1)
    }

    func testInsertTabIntoEmptyPane() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/x")
        let tab = source.extractTab(at: 0)!

        let dest = Pane()
        dest.insertTab(tab, at: 0)

        XCTAssertEqual(dest.tabs.count, 1)
        XCTAssertEqual(dest.activeTabIndex, 0)
        XCTAssertEqual(dest.activeTab?.workingDirectory, "/x")
    }

    // MARK: - Round-trip identity

    func testExtractThenInsertPreservesTabID() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/tmp")
        let originalID = source.tabs[0].id

        let tab = source.extractTab(at: 0)!
        let dest = Pane()
        dest.insertTab(tab, at: 0)

        XCTAssertEqual(dest.tabs[0].id, originalID)
    }

    func testExtractThenInsertPreservesWorkingDirectory() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/Users/test/project")

        let tab = source.extractTab(at: 0)!
        let dest = Pane()
        dest.insertTab(tab, at: 0)

        XCTAssertEqual(dest.activeTab?.workingDirectory, "/Users/test/project")
    }

    func testExtractThenInsertPreservesTitle() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/tmp")
        source.updateTitle(at: 0, "vim")

        let tab = source.extractTab(at: 0)!
        let dest = Pane()
        dest.insertTab(tab, at: 0)

        XCTAssertEqual(dest.tabs[0].title, "vim")
    }

    // MARK: - Cross-pane move simulation

    func testMovingTabBetweenPanesLeavesSourceEmpty() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/only")

        let tab = source.extractTab(at: 0)!
        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/existing")
        dest.insertTab(tab, at: 1)

        XCTAssertTrue(source.tabs.isEmpty)
        XCTAssertEqual(dest.tabs.count, 2)
    }

    func testMovingTabBetweenPanesMaintainsSourceActiveBounds() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/a")
        _ = source.addTab(workingDirectory: "/b")
        _ = source.addTab(workingDirectory: "/c")

        // Extract the middle tab (active = 2 after addTab)
        _ = source.extractTab(at: 1)

        // Active should remain in-bounds
        XCTAssertGreaterThanOrEqual(source.activeTabIndex, 0)
        XCTAssertLessThan(source.activeTabIndex, source.tabs.count)
    }
}
