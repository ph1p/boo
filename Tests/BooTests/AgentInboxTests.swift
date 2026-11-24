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

    /// SessionStart lists an idle agent (a resumed task) without asking for
    /// attention, and never resets one that is already listed.
    func testAStartedSessionIsListedIdleOnce() {
        let inbox = AgentInbox()
        let tab = UUID()
        XCTAssertNil(inbox.apply(event: "start", tabID: tab, cwd: "/src/api"))
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.needsAttention, false)
        XCTAssertEqual(inbox.items[tab]?.cwd, "/src/api")
        XCTAssertEqual(inbox.items[tab]?.fresh, true, "no turn yet")
        inbox.apply(event: "working", tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.fresh, false)
        inbox.apply(event: "start", tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.state, .working, "/clear and compaction also start a session")
    }

    func testAQuestionKeepsItsTextWhenThePermissionNoticeFollows() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "question", tabID: tab, message: "Red or blue?", tool: "AskUserQuestion")
        inbox.apply(event: "permission", tabID: tab, message: "Claude needs your permission")
        XCTAssertEqual(inbox.items[tab]?.state, .needsInput)
        XCTAssertEqual(inbox.items[tab]?.message, "Red or blue?")
        XCTAssertEqual(inbox.items[tab]?.asksQuestion, true, "no Allow / Deny: Return would pick option 1")

        inbox.apply(event: "tool", tabID: tab, tool: "AskUserQuestion")
        inbox.apply(event: "permission", tabID: tab, message: "Claude needs your permission to use Bash")
        XCTAssertEqual(
            inbox.items[tab]?.message, "Claude needs your permission to use Bash", "a new prompt has its own text")
        XCTAssertEqual(inbox.items[tab]?.asksQuestion, false, "a permission prompt takes Allow / Deny")
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

    /// A `claude -p` the agent runs in its tab inherits the tab's ID: its
    /// events must not end or overwrite the working agent's row.
    func testNestedSessionLeavesTheWorkingAgentAlone() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab, sessionID: "outer")
        inbox.apply(event: "prompt", tabID: tab, sessionID: "inner")
        inbox.apply(event: "stop", tabID: tab, sessionID: "inner")
        inbox.apply(event: "end", tabID: tab, sessionID: "inner")
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        XCTAssertEqual(inbox.items[tab]?.sessionID, "outer")

        inbox.apply(event: "stop", tabID: tab, sessionID: "outer")
        inbox.apply(event: "prompt", tabID: tab, sessionID: "cleared")
        XCTAssertEqual(inbox.items[tab]?.sessionID, "cleared", "after its turn a new session takes the tab")
        inbox.apply(event: "end", tabID: tab, sessionID: "cleared")
        XCTAssertNil(inbox.items[tab])
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

    func testOrchestratorEventsStayOutOfTheAgentList() {
        let inbox = makeInbox()
        let orchestratorTab = UUID()
        let orchestratorPane = UUID()
        inbox.orchestratorTabID = { orchestratorTab }
        inbox.orchestratorPaneID = { orchestratorPane }

        let byTab = inbox.handleSocketEvent(["tab_id": orchestratorTab.uuidString, "event": "permission"])
        XCTAssertEqual(byTab["ok"] as? Bool, true, "its tab is in no window but still resolves")
        XCTAssertEqual(inbox.orchestrator?.state, .needsInput)
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertEqual(inbox.attentionCount, 0)

        inbox.handleSocketEvent(["pane_id": orchestratorPane.uuidString, "event": "tool", "tool": "Bash"])
        XCTAssertEqual(inbox.orchestrator?.state, .working)
        XCTAssertEqual(inbox.orchestrator?.tool, "Bash")

        let listed = inbox.handleSocketCommand(cmd: "agent_inbox", json: [:])
        XCTAssertEqual((listed?["items"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(inbox.jumpToNextAttention())

        inbox.handleSocketEvent(["tab_id": orchestratorTab.uuidString, "event": "end"])
        XCTAssertNil(inbox.orchestrator)
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
        XCTAssertEqual((hooks["PreToolUse"] as? [[String: Any]])?.last?["matcher"] as? String, "AskUserQuestion")
        let start = (hooks["SessionStart"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]]
        XCTAssertNil(start?.first?["async"], "Claude ignores the context of async hooks")
        let stop = (hooks["Stop"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]]
        XCTAssertEqual(stop?.first?["async"] as? Bool, true)
        XCTAssertNil(BooPaths.mergingClaudeHook(command: command, into: merged), "second run changes nothing")
    }

    // MARK: - Reliability

    /// Hooks are separate processes: a report sent before the last one but
    /// handled after it is dropped.
    func testALateReportIsDropped() {
        let inbox = makeInbox()
        let tab = UUID()
        let start = Date()
        inbox.apply(event: "prompt", tabID: tab, reportedAt: start.addingTimeInterval(2))
        inbox.apply(event: "stop", tabID: tab, reportedAt: start.addingTimeInterval(1))
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        inbox.apply(event: "stop", tabID: tab, reportedAt: start.addingTimeInterval(3))
        XCTAssertEqual(inbox.items[tab]?.state, .done)
    }

    /// A nested `claude -p` shares the agent's process; another process with
    /// another session is a new agent in the tab, even while the old one worked.
    func testAnotherProcessIsANewAgentNotANestedSession() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab, sessionID: "outer", pid: 100)
        inbox.apply(event: "stop", tabID: tab, sessionID: "nested", pid: 100)
        XCTAssertEqual(inbox.items[tab]?.state, .working, "the nested session is ignored")

        inbox.apply(event: "start", tabID: tab, sessionID: "outer-clear", pid: 100)
        XCTAssertEqual(inbox.items[tab]?.state, .working, "the agent's own restart keeps its row")

        inbox.apply(event: "start", tabID: tab, sessionID: "new", pid: 200)
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.fresh, true, "a new agent replaced the one that quit")
        XCTAssertEqual(inbox.items[tab]?.pid, 200)
    }

    /// Codex reports a turn end twice; the second report has no reply.
    func testARepeatedStopKeepsTheReply() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "stop", tabID: tab, reply: "Done.")
        inbox.apply(event: "stop", tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.reply, "Done.")
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "stop", tabID: tab)
        XCTAssertNil(inbox.items[tab]?.reply, "a new turn does not inherit the old reply")
    }

    /// OpenCode idles after session.error; the stop must not hide the error.
    func testAStopAfterAnErrorKeepsTheError() {
        let inbox = makeInbox()
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "error", tabID: tab, message: "rate limit")
        inbox.apply(event: "stop", tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.state, .error)
        XCTAssertEqual(inbox.items[tab]?.message, "Stopped: rate limit")
        inbox.apply(event: "prompt", tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.state, .working, "the next prompt clears the error")
    }

    func testPresenceFollowsTheAgentProcess() {
        let inbox = makeInbox()
        let tab = UUID()
        var foreground: pid_t? = 100
        var alive = true
        inbox.foregroundPID = { _ in foreground }
        inbox.isAlive = { _ in alive }
        XCTAssertEqual(inbox.presence(of: tab), .foreground, "unknown counts as present")
        inbox.apply(event: "stop", tabID: tab, pid: 100)
        XCTAssertEqual(inbox.presence(of: tab), .foreground)
        foreground = 99
        XCTAssertEqual(inbox.presence(of: tab), .background)
        alive = false
        XCTAssertEqual(inbox.presence(of: tab), .gone)
        foreground = nil
        XCTAssertEqual(inbox.presence(of: tab), .foreground, "a closed terminal is not judged")
    }

    // MARK: - Background work

    /// A turn that ends while background commands run is not done: the agent
    /// stays working until they end, then finishes with that turn's reply.
    func testStopWithBackgroundShellsHoldsWorkingUntilTheyEnd() {
        let inbox = makeInbox()
        var shells: Set<pid_t> = [7]
        inbox.backgroundShells = { _ in shells }
        defer { inbox.stopBackgroundWatch() }
        let tab = UUID()
        let start = Date()
        inbox.apply(event: "prompt", tabID: tab, pid: 42, now: start)

        XCTAssertNil(inbox.apply(event: "stop", tabID: tab, reply: "Started the build.", pid: 42, now: start))
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        XCTAssertEqual(inbox.items[tab]?.tool, AgentInbox.backgroundTool)
        XCTAssertEqual(inbox.attentionCount, 0, "no ping while background work runs")

        inbox.checkBackground(now: start.addingTimeInterval(60))
        XCTAssertEqual(inbox.items[tab]?.state, .working, "still running")

        shells = []
        inbox.checkBackground(now: start.addingTimeInterval(62))
        XCTAssertEqual(inbox.items[tab]?.state, .working, "waits for the turn Claude starts on its own")
        inbox.checkBackground(now: start.addingTimeInterval(62 + AgentInbox.backgroundGrace))
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.reply, "Started the build.")
        XCTAssertEqual(inbox.attentionCount, 1)
        XCTAssertNil(inbox.backgroundTimer, "no held agent left to watch")
    }

    /// The turn Claude starts when its background work ends takes over; its own
    /// Stop finishes the agent.
    func testTheNextTurnEndsTheHold() {
        let inbox = makeInbox()
        var shells: Set<pid_t> = [7]
        inbox.backgroundShells = { _ in shells }
        defer { inbox.stopBackgroundWatch() }
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab, pid: 42)
        inbox.apply(event: "stop", tabID: tab, pid: 42)
        XCTAssertEqual(inbox.items[tab]?.holdsForBackground, true)

        shells = []
        inbox.apply(event: "tool", tabID: tab, tool: "Read", pid: 42)
        XCTAssertEqual(inbox.items[tab]?.holdsForBackground, false)
        XCTAssertEqual(inbox.items[tab]?.tool, "Read")
        XCTAssertEqual(inbox.apply(event: "stop", tabID: tab, reply: "Build passed.", pid: 42), .done)
        XCTAssertEqual(inbox.items[tab]?.reply, "Build passed.")
    }

    /// A background subagent holds the agent; its own tool calls do not end
    /// the hold, its SubagentStop does.
    func testBackgroundSubagentHoldsUntilItStops() {
        let inbox = makeInbox()
        inbox.backgroundShells = { _ in [] }
        defer { inbox.stopBackgroundWatch() }
        let tab = UUID()
        let start = Date()
        inbox.apply(event: "prompt", tabID: tab, now: start)
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "fg")
        inbox.apply(event: "subagent-stop", tabID: tab, subagentID: "fg")
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "bg")

        XCTAssertNil(inbox.apply(event: "stop", tabID: tab, now: start))
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        inbox.apply(event: "tool", tabID: tab, tool: "Grep", subagentID: "bg", now: start.addingTimeInterval(5))
        XCTAssertEqual(inbox.items[tab]?.holdsForBackground, true, "the subagent's tools are not a new turn")
        XCTAssertEqual(inbox.items[tab]?.tool, AgentInbox.backgroundTool)

        inbox.apply(event: "subagent-stop", tabID: tab, subagentID: "bg")
        inbox.checkBackground(now: start.addingTimeInterval(10))
        inbox.checkBackground(now: start.addingTimeInterval(10 + AgentInbox.backgroundGrace))
        XCTAssertEqual(inbox.items[tab]?.state, .done)
    }

    /// Hooks run as separate processes: a stop that arrives before its start
    /// leaves no subagent behind.
    func testASubagentStopBeforeItsStartCountsNothing() {
        let inbox = makeInbox()
        inbox.backgroundShells = { _ in [] }
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "subagent-stop", tabID: tab, subagentID: "a")
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "a")
        XCTAssertEqual(inbox.items[tab]?.subagents, [])
        // A repeated stop does not bring a finished subagent back.
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "b")
        inbox.apply(event: "subagent-stop", tabID: tab, subagentID: "b")
        inbox.apply(event: "subagent-stop", tabID: tab, subagentID: "b")
        XCTAssertEqual(inbox.items[tab]?.subagents, [])
        XCTAssertEqual(inbox.apply(event: "stop", tabID: tab), .done)
    }

    /// An interrupted subagent sends no SubagentStop: once it is quiet for
    /// `subagentQuiet` it holds neither the current turn nor a later one.
    func testAQuietSubagentStopsHoldingTheAgent() {
        let inbox = makeInbox()
        inbox.backgroundShells = { _ in [] }
        defer { inbox.stopBackgroundWatch() }
        let tab = UUID()
        let start = Date()
        inbox.apply(event: "prompt", tabID: tab, now: start)
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "lost", now: start)
        XCTAssertNil(inbox.apply(event: "stop", tabID: tab, now: start))
        XCTAssertEqual(inbox.items[tab]?.holdsForBackground, true)

        let quiet = start.addingTimeInterval(AgentInbox.subagentQuiet)
        inbox.checkBackground(now: quiet)
        inbox.checkBackground(now: quiet.addingTimeInterval(AgentInbox.backgroundGrace))
        XCTAssertEqual(inbox.items[tab]?.state, .done, "done long before backgroundLimit")

        inbox.apply(event: "prompt", tabID: tab, now: quiet.addingTimeInterval(60))
        XCTAssertEqual(
            inbox.apply(event: "stop", tabID: tab, now: quiet.addingTimeInterval(70)), .done,
            "the lost subagent holds no later turn")
        XCTAssertEqual(inbox.items[tab]?.subagents, [])
    }

    /// Esc ends a turn without a Stop and kills its foreground subagents.
    func testAnInterruptEndsTheTurnAndForgetsItsSubagents() {
        let inbox = makeInbox()
        inbox.backgroundShells = { _ in [] }
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab)
        inbox.apply(event: "subagent-start", tabID: tab, subagentID: "fg")
        inbox.interrupted(tabID: tab)
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.seen, true, "the user did it: no attention")
        XCTAssertEqual(inbox.items[tab]?.subagents, [])
    }

    /// The sweep drops agents whose tab closed (also behind a confirmation
    /// sheet, or with its workspace or window) and agents whose process exited
    /// without a SessionEnd. One with no known process stays while its tab does.
    func testSweepDropsClosedTabsAndExitedAgents() {
        let inbox = makeInbox()
        let open = UUID()
        let closed = UUID()
        let exited = UUID()
        let remote = UUID()
        let workspace = Workspace(folderPath: "/tmp")
        let pane = try! XCTUnwrap(workspace.pane(for: workspace.activePaneID))
        let controller = MainWindowController(restoreSession: false)
        Self.keptAlive.append(controller)
        inbox.locate = { id in
            id == closed
                ? nil : AgentInbox.Location(controller: controller, workspace: workspace, pane: pane, tabIndex: 0)
        }
        inbox.isAlive = { $0 != 2 }
        inbox.apply(event: "prompt", tabID: open, pid: 1)
        inbox.apply(event: "prompt", tabID: closed, pid: 1)
        inbox.apply(event: "stop", tabID: exited, pid: 2)
        inbox.apply(event: "working", tabID: remote)

        inbox.sweep()
        XCTAssertEqual(Set(inbox.items.keys), [open, remote])
    }

    /// Only Claude Code's shells are known; other agents end their turn as before.
    func testOtherAgentsAreNotHeld() {
        let inbox = makeInbox()
        inbox.backgroundShells = { _ in [7] }
        let tab = UUID()
        inbox.apply(event: "prompt", tabID: tab, agent: "codex", pid: 42)
        XCTAssertEqual(inbox.apply(event: "stop", tabID: tab, agent: "codex", pid: 42), .done)
    }

    /// A watcher never exits: after `backgroundLimit` the agent is done, and
    /// the same watcher holds no later turn.
    func testAWatcherIsWaitedOutOnce() {
        let inbox = makeInbox()
        var shells: Set<pid_t> = [7]
        inbox.backgroundShells = { _ in shells }
        defer { inbox.stopBackgroundWatch() }
        let tab = UUID()
        let start = Date()
        inbox.apply(event: "prompt", tabID: tab, pid: 42, now: start)
        inbox.apply(event: "stop", tabID: tab, reply: "Watching.", pid: 42, now: start)

        inbox.checkBackground(now: start.addingTimeInterval(AgentInbox.backgroundLimit - 1))
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        inbox.checkBackground(now: start.addingTimeInterval(AgentInbox.backgroundLimit))
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.reply, "Watching.")

        inbox.apply(event: "prompt", tabID: tab, pid: 42)
        XCTAssertEqual(inbox.apply(event: "stop", tabID: tab, pid: 42), .done, "the watcher was waited out")
        shells.insert(8)
        inbox.apply(event: "prompt", tabID: tab, pid: 42)
        XCTAssertNil(inbox.apply(event: "stop", tabID: tab, pid: 42), "a new background command holds again")
    }
}
