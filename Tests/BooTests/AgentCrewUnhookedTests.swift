import XCTest

@testable import Boo

/// Agents without Boo's hooks are found by their process and still listed.
@MainActor
final class AgentCrewUnhookedTests: XCTestCase {
    private func session(_ tabID: UUID, state: AgentRunState, cwd: String = "/tmp/api") -> WorkspaceAgentSession {
        WorkspaceAgentSession(
            id: tabID, paneID: UUID(), tabID: tabID, tabTitle: "claude", isFocused: false,
            agent: AgentSession(
                kind: .claudeCode, displayName: "Claude Code", processName: "claude", pid: nil, cwd: cwd,
                startedAt: Date(), state: state, sessionID: "s1", transcriptPath: nil, model: nil, mode: nil,
                metadata: [:]))
    }

    func testListsAgentsWithoutHooksInTheirWorkspace() {
        let hooked = UUID()
        let plain = UUID()
        let workspace = CrewWorkspace(id: UUID(), name: "api")
        let rows = AgentsPlugin.unhookedRows(
            sessions: [
                (session(hooked, state: .running), workspace),
                (session(plain, state: .needsInput), workspace)
            ],
            hooked: [hooked])

        XCTAssertEqual(rows.map(\.id), [plain], "a tab the inbox already lists is not listed twice")
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.handle, "", "no hooks, no handle")
        XCTAssertFalse(row.hasHooks)
        XCTAssertEqual(row.state, .needsInput)
        XCTAssertTrue(row.asksQuestion, "no Allow / Deny without a hook carrying the prompt")
        XCTAssertEqual(row.name, "Claude Code in api")
        XCTAssertEqual(row.folder, "/tmp/api")
        XCTAssertEqual(row.workspace, workspace)
    }

    func testIdleReadsDoneAndUnknownReadsWorking() {
        let idle = UUID()
        let unknown = UUID()
        let rows = AgentsPlugin.unhookedRows(
            sessions: [(session(idle, state: .idle), nil), (session(unknown, state: .unknown), nil)], hooked: [])
        XCTAssertEqual(rows.first { $0.id == idle }?.state, .done)
        XCTAssertEqual(rows.first { $0.id == unknown }?.state, .working)
    }

    func testMessagesAreNotOfferedWithoutHooks() {
        let ui = AgentCrewUIState.shared
        ui.close()
        defer { ui.close() }
        let row = AgentCrewRow(
            id: UUID(), handle: "", name: "Claude Code in api", agent: "claude", state: .done, detail: nil,
            parent: nil, queued: 0, needsAttention: false, isTask: false, hasHooks: false)
        AgentsPlugin.perform(.message, on: row)
        XCTAssertNil(ui.composer, "nothing would deliver the message")
    }
    func testUnhookedRowWaitsForTheHook() {
        let id = UUID()
        let row = AgentCrewRow(
            id: id, handle: "", name: "Claude Code in api", agent: "claude", state: .working, detail: nil,
            parent: nil, queued: 0, needsAttention: false, isTask: false, hasHooks: false)
        var seen: [UUID: Date] = [:]
        let start = Date()

        let early = AgentsPlugin.settledUnhooked([row], now: start, seen: &seen)
        XCTAssertTrue(early.rows.isEmpty, "a starting agent is not listed before its hook can report")
        XCTAssertEqual(early.recheckAt, start.addingTimeInterval(AgentsPlugin.unhookedGrace))

        let late = AgentsPlugin.settledUnhooked(
            [row], now: start.addingTimeInterval(AgentsPlugin.unhookedGrace + 0.1), seen: &seen)
        XCTAssertEqual(late.rows.map(\.id), [id], "no hook after the grace period: listed by process")
        XCTAssertNil(late.recheckAt)

        _ = AgentsPlugin.settledUnhooked([], now: start, seen: &seen)
        XCTAssertTrue(seen.isEmpty, "a gone agent is forgotten")
    }
}
