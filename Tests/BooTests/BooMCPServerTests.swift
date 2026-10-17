import XCTest

@testable import Boo

final class BooMCPServerTests: XCTestCase {
    private let ownPane = "11111111-1111-1111-1111-111111111111"
    private let otherPane = "22222222-2222-2222-2222-222222222222"

    /// Server whose socket replies come from `reply`; every sent command is recorded.
    private func makeServer(
        reply: @escaping ([String: Any]) throws -> [String: Any] = { _ in ["ok": true] }
    ) -> (BooMCPServer, () -> [[String: Any]]) {
        var sent: [[String: Any]] = []
        let server = BooMCPServer(
            send: { message in
                sent.append(message)
                return try reply(message)
            }, ownPaneID: ownPane, cwd: "/work/repo")
        return (server, { sent })
    }

    private func call(_ server: BooMCPServer, _ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": tool, "arguments": arguments]
        ])
        return response?["result"] as? [String: Any] ?? [:]
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testInitializeAndToolList() throws {
        let (server, sent) = makeServer()
        let initialize = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]
            ]))
        XCTAssertEqual(initialize["id"] as? Int, 1)
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26", "echoes the client's version")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "boo")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let list = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            [
                "get_layout", "split_pane", "read_pane", "send_text", "close_pane", "list_agents", "new_agent_task",
                "open_review"
            ])
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
        }
        XCTAssertTrue(sent().isEmpty, "no socket traffic for protocol messages")
    }

    func testNotificationsAndErrors() {
        let (server, _) = makeServer()
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "id": 3, "result": [:]]), "client responses get no reply")
        XCTAssertEqual(server.handle(["jsonrpc": "2.0", "id": 2, "method": "ping"])?["result"] as? [String: Int], [:])

        let unknown = server.handle(["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let badTool = server.handle([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm_rf"]
        ])
        XCTAssertEqual((badTool?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testSplitPaneDefaultsToOwnPaneUnfocusedInAgentCwd() {
        let (server, sent) = makeServer { _ in ["ok": true, "pane_id": "33333333-3333-3333-3333-333333333333"] }
        let result = call(server, "split_pane", ["command": "pnpm dev"])
        XCTAssertNil(result["isError"])
        XCTAssertTrue(text(result).contains("33333333-3333-3333-3333-333333333333"))
        let message = sent().first ?? [:]
        XCTAssertEqual(message["cmd"] as? String, "split_pane")
        XCTAssertEqual(message["pane_id"] as? String, ownPane)
        XCTAssertEqual(message["direction"] as? String, "right")
        XCTAssertEqual(message["focus"] as? Bool, false)
        XCTAssertEqual(message["cwd"] as? String, "/work/repo")
        XCTAssertEqual(message["command"] as? String, "pnpm dev")
    }

    func testReadAndSendTargetOtherPanes() {
        let (server, sent) = makeServer { message in
            message["cmd"] as? String == "get_screen" ? ["ok": true, "text": "ready on :3000"] : ["ok": true]
        }
        XCTAssertEqual(text(call(server, "read_pane", ["pane_id": otherPane, "lines": 20])), "ready on :3000")
        XCTAssertEqual(sent().last?["lines"] as? Int, 20)
        XCTAssertEqual(sent().last?["pane_id"] as? String, otherPane)

        XCTAssertEqual(text(call(server, "send_text", ["pane_id": otherPane, "text": "q"])), "sent")
        XCTAssertEqual(sent().last?["submit"] as? Bool, true)
        XCTAssertEqual(call(server, "read_pane")["isError"] as? Bool, true, "pane_id is required")
    }

    func testRefusesToTypeIntoOrCloseOwnPane() {
        let (server, sent) = makeServer()
        let typed = call(server, "send_text", ["pane_id": ownPane.uppercased(), "text": "rm -rf ."])
        XCTAssertEqual(typed["isError"] as? Bool, true)
        XCTAssertEqual(call(server, "close_pane", ["pane_id": ownPane])["isError"] as? Bool, true)
        XCTAssertTrue(sent().isEmpty)
    }

    func testBooErrorsAndMissingSocketBecomeToolErrors() {
        let (refusing, _) = makeServer { _ in ["ok": false, "error": "pane not found"] }
        let refused = call(refusing, "close_pane", ["pane_id": otherPane])
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertEqual(text(refused), "pane not found")

        let (offline, _) = makeServer { _ in throw BooMCPServer.Failure(message: "Boo is not running") }
        let result = call(offline, "get_layout")
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(text(result), "Boo is not running")
    }

    func testLayoutNamesYourPaneAndTaskUsesRepo() {
        let (server, sent) = makeServer { _ in ["ok": true, "path": "/wt/x", "workspace_id": "w"] }
        XCTAssertTrue(text(call(server, "get_layout")).contains("\"your_pane\" : \"\(ownPane)\""))
        _ = call(server, "new_agent_task", ["prompt": "fix the flaky test", "name": "flaky"])
        let task = sent().last ?? [:]
        XCTAssertEqual(task["repo"] as? String, "/work/repo")
        XCTAssertEqual(task["prompt"] as? String, "fix the flaky test")
        XCTAssertNil(task["pane_id"])
    }

    func testSocketClientReportsMissingSocket() {
        XCTAssertThrowsError(
            try BooSocketClient.request(["cmd": "ping"], socketPath: "/nonexistent/boo-\(UUID().uuidString).sock")
        ) { error in
            XCTAssertTrue((error as? BooMCPServer.Failure)?.message.contains("not running") == true)
        }
    }
}
