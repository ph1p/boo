import XCTest

@testable import Exterm

final class PaneViewIntegrationTests: XCTestCase {

    func testPaneCreationWithTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/tmp")
        XCTAssertEqual(pane.activeTab?.title, "tmp")
    }

    func testPaneWorkingDirectoryUpdate() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateWorkingDirectory(at: 0, "/Users/test/Documents")
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/Users/test/Documents")
        // Title stays at initial value — only updateTitle changes it
        XCTAssertEqual(pane.activeTab?.title, "tmp")
    }

    func testPaneTabSwitchingPreservesDirectories() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        XCTAssertEqual(pane.activeTab?.workingDirectory, "/b")

        pane.setActiveTab(0)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/a")

        pane.setActiveTab(1)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/b")
    }

    func testSplitPaneInheritsWorkingDirectory() {
        let ws = Workspace(folderPath: "/home/user")
        let originalPane = ws.pane(for: ws.activePaneID)
        originalPane?.updateWorkingDirectory(at: 0, "/home/user/projects")

        let newID = ws.splitPane(ws.activePaneID, direction: .horizontal)
        let newPane = ws.pane(for: newID)

        // New pane should inherit the current working directory
        XCTAssertEqual(newPane?.activeTab?.workingDirectory, "/home/user/projects")
    }
    func testTerminalColorConversion() {
        let c = TerminalColor(r: 128, g: 64, b: 255)
        XCTAssertNotNil(c.cgColor)
        XCTAssertNotNil(c.nsColor)
        XCTAssertEqual(c.nsColor.redComponent, 128.0 / 255.0, accuracy: 0.01)
    }
}
