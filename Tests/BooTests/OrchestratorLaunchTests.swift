import XCTest

@testable import Boo

@MainActor
final class OrchestratorLaunchTests: XCTestCase {
    func testFreshCommandPinsTheSessionID() {
        let line = OrchestratorLaunch.command(
            sessionID: "abc", resume: false, mcpConfig: "/m/mcp.json", promptFile: "/p/prompt.md")
        XCTAssertEqual(
            line,
            "exec claude --session-id 'abc' --mcp-config '/m/mcp.json' --append-system-prompt \"$(cat '/p/prompt.md')\"")
    }

    func testResumeCommandWithNotice() {
        let line = OrchestratorLaunch.command(
            sessionID: "abc", resume: true, mcpConfig: "/m", promptFile: "/p", notice: "gone; new")
        XCTAssertTrue(line.hasPrefix("echo 'gone; new'; exec claude --resume 'abc' "))
    }

    func testQuoteEscapesApostrophes() {
        XCTAssertEqual(OrchestratorLaunch.quote("/Users/o'neil/x"), "'/Users/o'\\''neil/x'")
    }

    func testSpecSetsToolTimeout() {
        XCTAssertEqual(OrchestratorLaunch.spec(command: "x").env["MCP_TOOL_TIMEOUT"], "600000")
    }

    func testMCPConfigStartsBooInMCPMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try OrchestratorLaunch.writeMCPConfig(executable: "/Apps/Boo", directory: dir)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let boo = (json?["mcpServers"] as? [String: Any])?["boo"] as? [String: Any]
        XCTAssertEqual(boo?["command"] as? String, "/Apps/Boo")
        XCTAssertEqual(boo?["args"] as? [String], ["--mcp"])
    }

    func testPromptIsBundled() throws {
        let url = try XCTUnwrap(OrchestratorLaunch.promptURL)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("wait_for_events"))
    }

    func testSnapshotKeepsOrchestratorSession() throws {
        var snapshot = SessionSnapshot(activeWorkspaceIndex: 0, workspaces: [])
        snapshot.orchestrator = OrchestratorSession(sessionID: "s1", ownedWorktrees: ["/w/a"])
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.orchestrator, snapshot.orchestrator)

        let old = #"{"activeWorkspaceIndex":0,"workspaces":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionSnapshot.self, from: Data(old.utf8)).orchestrator)
    }

    func testSessionDropsVanishedWorktrees() {
        let existing = NSTemporaryDirectory()
        let controller = OrchestratorController()
        controller.restore(
            OrchestratorSession(sessionID: "s1", ownedWorktrees: [existing, "/nonexistent/\(UUID())"]), in: [])
        XCTAssertEqual(controller.session?.sessionID, "s1")
        XCTAssertEqual(controller.session?.ownedWorktrees, [existing])
        XCTAssertTrue(controller.canResume)
    }

    func testNothingToKeepWithoutSessionOrWorktrees() {
        XCTAssertNil(OrchestratorController().session)
    }
}
