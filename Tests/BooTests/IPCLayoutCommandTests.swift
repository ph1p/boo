import XCTest

@testable import Boo

@MainActor
final class IPCLayoutCommandTests: XCTestCase {
    /// Controllers are never released: tearing down live surfaces can hang the suite.
    private static var keptAlive: [MainWindowController] = []

    private func makeController() throws -> (MainWindowController, Workspace) {
        let controller = MainWindowController(restoreSession: false)
        Self.keptAlive.append(controller)
        return (controller, try XCTUnwrap(controller.activeWorkspace))
    }

    /// Runs a command; replies arrive synchronously for layout commands.
    private func run(_ controller: MainWindowController, _ json: [String: Any]) -> [String: Any] {
        var response: [String: Any] = [:]
        controller.handleIPCCommand(cmd: json["cmd"] as? String ?? "", json: json) { response = $0 }
        return response
    }

    func testSplitPlacesNewPaneOnRequestedEdge() throws {
        let (controller, workspace) = try makeController()
        let original = workspace.activePaneID

        let reply = run(controller, ["cmd": "split_pane", "direction": "left"])

        XCTAssertEqual(reply["ok"] as? Bool, true)
        let newID = try XCTUnwrap((reply["pane_id"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(workspace.splitTree.leafIDs, [newID, original])
        XCTAssertEqual(workspace.activePaneID, newID)
    }

    func testSplitRejectsUnknownDirection() throws {
        let (controller, workspace) = try makeController()
        let reply = run(controller, ["cmd": "split_pane", "direction": "sideways"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(workspace.splitTree.leafCount, 1)
    }

    func testFocusSwapZoomAndClose() throws {
        let (controller, workspace) = try makeController()
        let first = workspace.activePaneID
        _ = run(controller, ["cmd": "split_pane", "direction": "right"])
        let second = workspace.activePaneID

        XCTAssertEqual(
            run(controller, ["cmd": "focus_pane", "direction": "left"])["active_pane"] as? String,
            first.uuidString)
        _ = run(controller, ["cmd": "swap_pane", "direction": "right"])
        XCTAssertEqual(workspace.splitTree.leafIDs, [second, first])

        XCTAssertEqual(run(controller, ["cmd": "zoom_pane"])["zoomed"] as? Bool, true)
        XCTAssertEqual(workspace.zoomedPaneID, first)
        XCTAssertEqual(run(controller, ["cmd": "zoom_pane", "zoomed": true])["zoomed"] as? Bool, true)
        XCTAssertEqual(run(controller, ["cmd": "zoom_pane", "zoomed": false])["zoomed"] as? Bool, false)

        XCTAssertEqual(run(controller, ["cmd": "close_pane", "pane_id": second.uuidString])["ok"] as? Bool, true)
        XCTAssertEqual(workspace.splitTree.leafIDs, [first])
        XCTAssertEqual(run(controller, ["cmd": "close_pane"])["ok"] as? Bool, false, "only pane stays")
    }

    func testPaneIDTargetsNamedPane() throws {
        let (controller, workspace) = try makeController()
        let first = workspace.activePaneID
        _ = run(controller, ["cmd": "split_pane", "direction": "right"])
        let second = workspace.activePaneID

        XCTAssertEqual(
            run(controller, ["cmd": "focus_pane", "pane_id": first.uuidString])["active_pane"] as? String,
            first.uuidString)
        XCTAssertEqual(run(controller, ["cmd": "zoom_pane", "pane_id": second.uuidString])["zoomed"] as? Bool, true)
        XCTAssertEqual(workspace.zoomedPaneID, second)
        XCTAssertEqual(workspace.activePaneID, second)
        _ = run(controller, ["cmd": "zoom_pane", "zoomed": false])

        _ = run(controller, ["cmd": "focus_pane", "pane_id": first.uuidString])
        _ = run(controller, ["cmd": "swap_pane", "direction": "left", "pane_id": second.uuidString])
        XCTAssertEqual(workspace.splitTree.leafIDs, [second, first])
        XCTAssertEqual(
            run(controller, ["cmd": "resize_pane", "direction": "left", "pane_id": UUID().uuidString])["ok"] as? Bool,
            false)
    }

    func testGetLayoutDescribesTree() throws {
        let (controller, workspace) = try makeController()
        _ = run(controller, ["cmd": "split_pane", "direction": "down"])

        let layout = run(controller, ["cmd": "get_layout"])

        XCTAssertEqual(layout["ok"] as? Bool, true)
        XCTAssertEqual(layout["active_pane"] as? String, workspace.activePaneID.uuidString)
        let tree = try XCTUnwrap(layout["tree"] as? [String: Any])
        XCTAssertEqual(tree["direction"] as? String, "vertical")
        XCTAssertEqual(try XCTUnwrap(tree["ratio"] as? Double), 0.5, accuracy: 0.001)
        let panes = try XCTUnwrap(layout["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.map { $0["id"] as? String }, workspace.splitTree.leafIDs.map(\.uuidString))
    }

    func testResizeMovesDivider() throws {
        let (controller, workspace) = try makeController()
        _ = run(controller, ["cmd": "split_pane", "direction": "right"])
        _ = run(controller, ["cmd": "resize_pane", "direction": "left", "amount": 100])
        guard case .split(_, _, _, let ratio) = workspace.splitTree else { return XCTFail("expected split") }
        XCTAssertLessThan(ratio, 0.5)
        XCTAssertEqual(run(controller, ["cmd": "resize_pane"])["ok"] as? Bool, false)
    }
}
