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
        XCTAssertEqual(pane.activeTab?.title, "Documents")
    }

    func testWorkspaceCwdTracking() {
        let ws = Workspace(folderPath: "/tmp")
        XCTAssertEqual(ws.currentDirectory, "/tmp")

        var notified = false
        ws.onDirectoryChanged = { path in
            XCTAssertEqual(path, "/Users/test")
            notified = true
        }

        ws.handleDirectoryChange("/Users/test")
        XCTAssertTrue(notified)
        XCTAssertEqual(ws.currentDirectory, "/Users/test")
    }

    func testWorkspaceCwdNoOpForSameDirectory() {
        let ws = Workspace(folderPath: "/tmp")
        var callCount = 0
        ws.onDirectoryChanged = { _ in callCount += 1 }

        ws.handleDirectoryChange("/tmp") // same
        XCTAssertEqual(callCount, 0, "Should not notify for same directory")
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

    func testGhosttyRuntimeAvailable() {
        let runtime = GhosttyRuntime.shared
        XCTAssertNotNil(runtime.app, "Ghostty runtime should initialize")
        XCTAssertNotNil(runtime.config, "Ghostty config should exist")
    }

    func testGhosttyConfigReload() {
        let runtime = GhosttyRuntime.shared
        // Should not crash
        runtime.reloadConfig()
        XCTAssertNotNil(runtime.config)
    }

    func testTerminalColorConversion() {
        let c = TerminalColor(r: 128, g: 64, b: 255)
        XCTAssertNotNil(c.cgColor)
        XCTAssertNotNil(c.nsColor)
        XCTAssertEqual(c.nsColor.redComponent, 128.0/255.0, accuracy: 0.01)
    }
}
