import XCTest

@testable import Exterm

@MainActor
final class LocalFileTreePluginTests: XCTestCase {

    func testWhenClauseIsNotRemote() {
        let plugin = LocalFileTreePlugin()
        XCTAssertEqual(plugin.manifest.when, "!remote")
    }

    func testVisibleForLocalContext() {
        let plugin = LocalFileTreePlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/test/project",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertTrue(
            plugin.isVisible(for: context),
            "Local file tree plugin should be visible when not remote")
    }

    func testHiddenForRemoteContext() {
        let plugin = LocalFileTreePlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/test/project",
            remoteSession: .ssh(host: "user@remote"),
            gitContext: nil,
            processName: "ssh",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertFalse(
            plugin.isVisible(for: context),
            "Local file tree plugin should be hidden when remote")
    }

    func testPluginID() {
        let plugin = LocalFileTreePlugin()
        XCTAssertEqual(plugin.manifest.id, "file-tree-local")
    }
}
