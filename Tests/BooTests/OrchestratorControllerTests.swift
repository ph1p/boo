import XCTest

@testable import Boo

@MainActor
final class OrchestratorControllerTests: XCTestCase {
    func testHostHasStableIDsAndAGatedToken() {
        let controller = OrchestratorController()
        XCTAssertNil(controller.paneID)
        let host = controller.ensureHost(workingDirectory: "/tmp")
        XCTAssertTrue(controller.ensureHost() === host, "one host per app session")
        XCTAssertEqual(controller.tabID, host.tabID)
        XCTAssertTrue(controller.isOrchestratorPane(host.paneID))
        XCTAssertFalse(controller.isOrchestratorPane(UUID()))
        let token = CapabilityTokens.shared.token(for: host.tabID)
        XCTAssertEqual(CapabilityTokens.shared.resolve(token)?.grade, .gated)
        XCTAssertFalse(controller.isRunning)
    }

    func testCommandsOtherThanReadsAreRefused() {
        let controller = OrchestratorController()
        var replies: [[String: Any]] = []
        controller.handleIPCCommand(cmd: "get_screen", json: [:]) { replies.append($0) }
        XCTAssertEqual(replies.last?["error"] as? String, "orchestrator is not running")

        _ = controller.ensureHost(workingDirectory: "/tmp")
        controller.handleIPCCommand(cmd: "get_screen", json: [:]) { replies.append($0) }
        XCTAssertEqual(replies.last?["error"] as? String, "pane has no running terminal")
        controller.handleIPCCommand(cmd: "split_pane", json: [:]) { replies.append($0) }
        XCTAssertTrue((replies.last?["error"] as? String)?.contains("not in a workspace") == true)
    }
}
