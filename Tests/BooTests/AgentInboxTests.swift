import XCTest

@testable import Boo

@MainActor
final class AgentInboxTests: XCTestCase {
    private func makeInbox() -> AgentInbox {
        let inbox = AgentInbox()
        // No real windows: tabs resolve nowhere unless a test says otherwise.
        inbox.locate = { _ in nil }
        return inbox
    }

    func testPermissionNeedsAttentionUntilAgentWorksAgain() {
        let inbox = makeInbox()
        let tab = UUID()

        XCTAssertNil(inbox.apply(event: "prompt", tabID: tab))
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        XCTAssertEqual(inbox.attentionCount, 0)

        let state = inbox.apply(
            event: "permission", tabID: tab, message: "Claude needs your permission to use Bash")
        XCTAssertEqual(state, .needsInput, "entering needs-input asks the caller to notify")
        XCTAssertEqual(inbox.attentionCount, 1)
        inbox.markSeen(tabID: tab)
        XCTAssertEqual(inbox.attentionCount, 1, "a permission prompt waits even after being looked at")
        XCTAssertNil(inbox.apply(event: "permission", tabID: tab), "repeat events do not notify twice")

        inbox.apply(event: "tool", tabID: tab, tool: "Bash")
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        XCTAssertEqual(inbox.items[tab]?.tool, "Bash")
        XCTAssertNil(inbox.items[tab]?.message)
        XCTAssertEqual(inbox.attentionCount, 0)
    }

    func testDoneWaitsUntilSeenAndEndRemoves() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab, sessionID: "s1", cwd: "/repo")

        XCTAssertEqual(inbox.apply(event: "stop", tabID: tab), .done)
        XCTAssertEqual(inbox.attentionCount, 1)
        XCTAssertEqual(inbox.items[tab]?.sessionID, "s1", "later events keep session and cwd")
        inbox.markSeen(tabID: tab)
        XCTAssertEqual(inbox.attentionCount, 0)
        XCTAssertNotNil(inbox.items[tab], "seen agents stay listed")

        inbox.apply(event: "end", tabID: tab)
        XCTAssertNil(inbox.items[tab])
        XCTAssertNil(inbox.apply(event: "bogus", tabID: tab))
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testSortsWaitingAgentsFirst() {
        let inbox = makeInbox()
        let working = UUID()
        let done = UUID()
        let asking = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        inbox.apply(event: "stop", tabID: done, now: start)
        inbox.apply(event: "permission", tabID: asking, now: start.addingTimeInterval(-10))
        inbox.apply(event: "prompt", tabID: working, now: start.addingTimeInterval(10))

        XCTAssertEqual(inbox.sortedItems.map(\.tabID), [asking, done, working])
    }

    func testSummaries() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(
            event: "permission", tabID: tab, agent: "claude", message: "Claude needs your permission to use Bash")
        let item = try! XCTUnwrap(inbox.items[tab])
        XCTAssertEqual(AgentInbox.summary(of: item), "Claude needs your permission to use Bash")
        XCTAssertEqual(AgentInbox.summary(of: item, short: true), "Claude needs your input")

        inbox.apply(event: "stop", tabID: tab, agent: "codex")
        XCTAssertEqual(AgentInbox.summary(of: try! XCTUnwrap(inbox.items[tab])), "Codex is done")
    }

    func testSocketEventNeedsAKnownTab() {
        let inbox = makeInbox()
        let reply = inbox.handleSocketCommand(
            cmd: "agent_event", json: ["event": "stop", "tab_id": UUID().uuidString])
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(inbox.handleSocketCommand(cmd: "agent_event", json: [:])?["error"] as? String, "missing event")
        XCTAssertNil(inbox.handleSocketCommand(cmd: "get_layout", json: [:]), "other commands pass through")
        XCTAssertEqual(inbox.handleSocketCommand(cmd: "agent_inbox", json: [:])?["attention"] as? Int, 0)
    }

    func testPruneDropsClosedTabs() {
        let inbox = makeInbox()
        let open = UUID()
        let closed = UUID()
        inbox.apply(event: "stop", tabID: open)
        inbox.apply(event: "stop", tabID: closed)
        let workspace = Workspace(folderPath: "/tmp")
        let pane = try! XCTUnwrap(workspace.pane(for: workspace.activePaneID))
        let controller = MainWindowController(restoreSession: false)
        Self.keptAlive.append(controller)
        inbox.locate = { id in
            id == open
                ? AgentInbox.Location(controller: controller, workspace: workspace, pane: pane, tabIndex: 0) : nil
        }

        inbox.prune()

        XCTAssertEqual(Array(inbox.items.keys), [open])
    }

    /// Controllers are never released: tearing down live surfaces can hang the suite.
    private static var keptAlive: [MainWindowController] = []

    // MARK: Hook installer

    func testHookInstallerAddsEveryEventOnceAndKeepsUserHooks() throws {
        let command = "/x/boo-claude-hook"
        let userHook: [String: Any] = [
            "matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]
        ]
        let legacyStop: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true]]]
        let root: [String: Any] = [
            "model": "opus", "hooks": ["PostToolUse": [userHook], "Stop": [legacyStop]]
        ]

        let merged = try XCTUnwrap(BooPaths.mergingClaudeHook(command: command, into: root))

        XCTAssertEqual(merged["model"] as? String, "opus")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        for event in BooPaths.claudeHookEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            let ours = entries.filter { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } ?? false
            }
            XCTAssertEqual(ours.count, 1, event)
        }
        XCTAssertEqual((hooks["PostToolUse"] as? [[String: Any]])?.first?["matcher"] as? String, "Bash")
        XCTAssertNil(BooPaths.mergingClaudeHook(command: command, into: merged), "second run changes nothing")
    }
}
