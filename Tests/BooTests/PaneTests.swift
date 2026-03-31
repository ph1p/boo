import XCTest

@testable import Boo

final class PaneTests: XCTestCase {

    func testAddTab() {
        let pane = Pane()
        let idx = pane.addTab(workingDirectory: "/tmp")
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.activeTabIndex, 0)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/tmp")
    }

    func testMultipleTabs() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        _ = pane.addTab(workingDirectory: "/home")
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabIndex, 1)  // Last added is active
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/home")
    }

    func testSetActiveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.setActiveTab(0)
        XCTAssertEqual(pane.activeTabIndex, 0)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/a")
    }

    func testSetActiveTabOutOfBounds() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        pane.setActiveTab(5)
        XCTAssertEqual(pane.activeTabIndex, 0)  // Unchanged
    }

    func testRemoveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.removeTab(at: 1)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/c")
    }

    func testRemoveActiveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.removeTab(at: 1)  // Remove active
        XCTAssertEqual(pane.activeTabIndex, 0)
    }

    func testRemoveAllTabs() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        pane.removeTab(at: 0)
        XCTAssertTrue(pane.tabs.isEmpty)
        XCTAssertEqual(pane.activeTabIndex, -1)
    }

    func testUpdateTitle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateTitle(at: 0, "newTitle")
        XCTAssertEqual(pane.tabs[0].title, "newTitle")
    }

    func testStopAll() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.stopAll()
        XCTAssertTrue(pane.tabs.isEmpty)
    }

    func testTabTitle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/Users/test/Documents")
        XCTAssertEqual(pane.tabs[0].title, "Documents")
    }

    func testUpdateRemoteSession() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        XCTAssertNil(pane.activeTab?.remoteSession)
        pane.updateRemoteSession(at: 0, .ssh(host: "user@server"))
        XCTAssertEqual(pane.activeTab?.remoteSession, .ssh(host: "user@server"))
        pane.updateRemoteSession(at: 0, nil)
        XCTAssertNil(pane.activeTab?.remoteSession)
    }

    func testCloseActiveTabSelectsNeighbor() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.removeTab(at: 2)
        XCTAssertEqual(pane.activeTabIndex, 1)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/b")
    }

    func testCloseMiddleTabPreservesActive() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActiveTab(2)
        pane.removeTab(at: 1)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/c")
    }
}
