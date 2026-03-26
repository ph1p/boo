import XCTest

@testable import Exterm

/// Tests that socket event serialization and context include pane_id.
@MainActor
final class SocketPaneIDTests: XCTestCase {

    // MARK: - get_context includes pane_id

    func testSerializeContextIncludesPaneID() {
        let paneID = UUID()
        let ctx = TerminalContext(
            terminalID: paneID, cwd: "/tmp",
            remoteSession: nil, gitContext: nil,
            processName: "", paneCount: 1, tabCount: 1
        )
        let dict = ExtermSocketServer.serializeContext(ctx)
        XCTAssertEqual(dict["pane_id"] as? String, paneID.uuidString)
        XCTAssertEqual(dict["terminal_id"] as? String, paneID.uuidString)
    }

    func testSerializeContextPaneIDMatchesTerminalID() {
        let id = UUID()
        let ctx = TerminalContext(
            terminalID: id, cwd: "/home",
            remoteSession: .ssh(host: "user@host"),
            remoteCwd: "/remote",
            gitContext: nil, processName: "vim",
            paneCount: 2, tabCount: 3
        )
        let dict = ExtermSocketServer.serializeContext(ctx)
        XCTAssertEqual(
            dict["pane_id"] as? String,
            dict["terminal_id"] as? String,
            "pane_id and terminal_id should be identical")
    }

    // MARK: - Context builder pane-ID awareness

    func testBuildContextUsesTabStateForNonActivePaneBridge() {
        let activePaneID = UUID()
        let otherPaneID = UUID()
        let bridge = TerminalBridge(paneID: otherPaneID, workspaceID: UUID(), workingDirectory: "/other")
        // Set bridge to a different pane's SSH session
        bridge.restoreTabState(
            paneID: otherPaneID, tabID: UUID(), workingDirectory: "/other",
            terminalTitle: "", remoteSession: .ssh(host: "stale-host"), remoteCwd: "/stale")

        let coordinator = WindowStateCoordinator(bridge: bridge, pluginRegistry: PluginRegistry())

        var tabState = TabState(workingDirectory: "/correct", title: "")
        tabState.remoteSession = .ssh(host: "correct-host")

        let ctx = coordinator.buildContext(
            paneID: activePaneID,
            tabState: tabState,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        // Bridge paneID != activePaneID, so should fall back to tab state
        if case .ssh(let host, _) = ctx.remoteSession {
            XCTAssertEqual(host, "correct-host", "Should use tab state, not stale bridge state")
        } else {
            XCTFail("Expected SSH session from tab state")
        }
    }

    func testBuildContextUsesBridgeForActivePaneBridge() {
        let paneID = UUID()
        let bridge = TerminalBridge(paneID: paneID, workspaceID: UUID(), workingDirectory: "/bridge")
        bridge.restoreTabState(
            paneID: paneID, tabID: UUID(), workingDirectory: "/bridge",
            terminalTitle: "", remoteSession: .ssh(host: "bridge-host"), remoteCwd: "/bridge/cwd")

        let coordinator = WindowStateCoordinator(bridge: bridge, pluginRegistry: PluginRegistry())

        var tabState = TabState(workingDirectory: "/tab", title: "")
        tabState.remoteSession = .ssh(host: "tab-host")

        let ctx = coordinator.buildContext(
            paneID: paneID,
            tabState: tabState,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )

        // Bridge paneID == activePaneID, so should use bridge state
        if case .ssh(let host, _) = ctx.remoteSession {
            XCTAssertEqual(host, "bridge-host", "Should use bridge state for active pane")
        } else {
            XCTFail("Expected SSH session from bridge state")
        }
        XCTAssertEqual(ctx.remoteCwd, "/bridge/cwd")
    }
}
