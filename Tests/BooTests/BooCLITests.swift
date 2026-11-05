import XCTest

@testable import Boo

final class BooCLITests: XCTestCase {
    private let env = ["BOO_PANE_ID": "11111111-1111-1111-1111-111111111111", "BOO_TOKEN": "tok"]

    private func run(
        _ arguments: [String], env: [String: String]? = nil,
        reply: [String: Any] = ["ok": true]
    ) -> (BooCLI.Output, [[String: Any]]) {
        var sent: [[String: Any]] = []
        let output = BooCLI.run(arguments, env: env ?? self.env, cwd: "/work/repo") { message in
            sent.append(message)
            return reply
        }
        return (output, sent)
    }

    func testRunStartsWorktreeTaskWithOptions() {
        let (output, sent) = run(
            ["run", "--agent", "codex", "--name", "lint", "fix", "the", "lint"],
            reply: ["ok": true, "handle": "t4", "branch": "boo/lint"])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.text, "started t4 on boo/lint; it reports back here when done")
        let message = sent.first ?? [:]
        XCTAssertEqual(message["cmd"] as? String, "new_agent_task")
        XCTAssertEqual(message["repo"] as? String, "/work/repo")
        XCTAssertEqual(message["agent"] as? String, "codex")
        XCTAssertEqual(message["name"] as? String, "lint")
        XCTAssertEqual(message["prompt"] as? String, "fix the lint")
        XCTAssertEqual(message["token"] as? String, "tok")
        XCTAssertEqual(message["pane_id"] as? String, env["BOO_PANE_ID"])
        XCTAssertNil(message["worktree"])
    }

    func testRunHereStartsHelperBeside() {
        let (output, sent) = run(["run", "--here", "--", "--not-a-flag"], reply: ["ok": true, "handle": "t5"])
        XCTAssertEqual(output.text, "started t5 next to this tab; it reports back here when done")
        XCTAssertEqual(sent.first?["worktree"] as? Bool, false)
        XCTAssertEqual(sent.first?["cwd"] as? String, "/work/repo")
        XCTAssertEqual(sent.first?["prompt"] as? String, "--not-a-flag")
    }

    func testUsageErrors() {
        XCTAssertEqual(run([]).0.status, 2)
        XCTAssertEqual(run(["run"]).0.status, 2)
        XCTAssertEqual(run(["run", "--agent"]).0.status, 2)
        XCTAssertEqual(run(["run", "--bogus", "x"]).0.status, 2)
        XCTAssertEqual(run(["send", "t3"]).0.status, 2)
        XCTAssertEqual(run(["status", "sleeping"]).0.status, 2)
        XCTAssertEqual(run(["frobnicate"]).0.status, 2)
        XCTAssertEqual(run(["help"]).0.status, 0)
        XCTAssertTrue(run([]).1.isEmpty, "usage errors send nothing")
    }

    func testSendReportsQueuedAndRefusals() {
        let (queued, sent) = run(
            ["send", "t3", "also", "lint"], reply: ["ok": true, "status": "queued", "to": "t3 docs"])
        XCTAssertEqual(queued.text, "queued for t3 docs (delivered when it finishes its turn)")
        XCTAssertEqual(sent.first?["cmd"] as? String, "agent_send")
        XCTAssertEqual(sent.first?["to"] as? String, "t3")
        XCTAssertEqual(sent.first?["text"] as? String, "also lint")

        let (refused, _) = run(["send", "t9", "x"], reply: ["ok": false, "error": "no agent t9"])
        XCTAssertEqual(refused, BooCLI.Output(text: "boo: no agent t9", status: 1))
    }

    func testStatusMapsToAgentEvents() {
        var (output, sent) = run(["status", "done", "All", "green"], env: env.merging(["BOO_AGENT": "ci"]) { $1 })
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(sent.first?["cmd"] as? String, "agent_event")
        XCTAssertEqual(sent.first?["event"] as? String, "done")
        XCTAssertEqual(sent.first?["agent"] as? String, "ci")
        XCTAssertEqual(sent.first?["reply"] as? String, "All green")

        (output, sent) = run(["status", "blocked", "need", "a", "key"])
        XCTAssertEqual(sent.first?["event"] as? String, "needs-input")
        XCTAssertEqual(sent.first?["agent"] as? String, "script")
        XCTAssertEqual(sent.first?["message"] as? String, "need a key")

        (output, _) = run(["status", "working"], env: [:])
        XCTAssertEqual(output.status, 1, "needs a Boo terminal")
    }

    func testInboxPrintsEnvelope() {
        let (output, _) = run(
            ["inbox"], reply: ["ok": true, "messages": [["from": "t2 docs", "state": "done", "text": "ok"]]])
        XCTAssertEqual(output.text, "<boo from=\"t2 docs\" state=\"done\">\nok\n</boo>")
    }

    func testAgentsTable() {
        let table = BooCLI.agentsTable([
            "items": [
                ["handle": "t2", "state": "working", "name": "docs", "parent": "t1", "queued": 2],
                ["handle": "t1", "state": "done", "name": "main"]
            ]
        ])
        XCTAssertEqual(
            table,
            "t1   done         main\nt2   working      docs  (from t1)  [2 queued]")
        XCTAssertEqual(BooCLI.agentsTable(["items": []]), "no agents")
        XCTAssertEqual(
            BooCLI.agentsTable(
                ["items": [["handle": "t2", "state": "done", "name": "poem", "tab_id": "A"]]], you: "A"),
            "t2   done         poem  (you)")
        XCTAssertEqual(
            BooCLI.agentsTable([
                "items": [["handle": "t1", "state": "working", "name": "", "agent": "claude", "cwd": "/w/boo"]]
            ]),
            "t1   working      claude in boo")
    }

    private func waitOutput(_ states: [String?], timeout: TimeInterval? = nil) -> (BooCLI.Output, Int) {
        var polls = 0
        let output = try! BooCLI.wait(
            for: "t4", timeout: timeout,
            poll: {
                let state = states[min(polls, states.count - 1)]
                polls += 1
                guard let state else { return ["ok": true, "items": []] }
                return [
                    "ok": true,
                    "items": [["handle": "t4", "state": state, "reply": "Tests pass.", "message": "Which DB?"]]
                ]
            }, sleep: { _ in })
        return (output, polls)
    }

    func testWaitReturnsTheAnswerAfterTheTurn() {
        let (output, polls) = waitOutput([nil, "working", "working", "done"])
        XCTAssertEqual(output, BooCLI.Output(text: "Tests pass.", status: 0))
        XCTAssertEqual(polls, 4)
    }

    func testWaitIgnoresThePreviousTurnUntilItSettles() {
        let (output, polls) = waitOutput(["done", "done", "done", "done", "done"])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(polls, 4, "an idle agent counts after 3 seconds")
        XCTAssertEqual(waitOutput(["done", "working", "done"]).1, 3, "a new turn ends the wait right away")
    }

    /// SessionStart lists a new helper as idle before it reads its prompt:
    /// that is no answer yet.
    func testWaitGivesANewHelperTimeToStart() throws {
        var polls = 0
        func row(_ state: String, fresh: Bool) -> [String: Any] {
            ["ok": true, "items": [["handle": "t4", "state": state, "fresh": fresh, "reply": "Tests pass."]]]
        }
        let output = try BooCLI.wait(
            for: "t4", timeout: nil,
            poll: {
                polls += 1
                return polls <= 10
                    ? row("done", fresh: true) : polls == 11 ? row("working", fresh: false) : row("done", fresh: false)
            }, sleep: { _ in })
        XCTAssertEqual(output, BooCLI.Output(text: "Tests pass.", status: 0))
        polls = 0
        let idle = try BooCLI.wait(
            for: "t4", timeout: nil,
            poll: {
                polls += 1
                return row("done", fresh: true)
            }, sleep: { _ in })
        XCTAssertEqual(idle, BooCLI.Output(text: "t4 idles at its prompt", status: 0))
        XCTAssertEqual(polls, 61, "a helper that never starts gives up after a minute")
    }

    func testWaitReportsQuestionsExitAndTimeout() {
        XCTAssertEqual(waitOutput(["working", "needs-input"]).0, BooCLI.Output(text: "t4 asks: Which DB?", status: 3))
        XCTAssertEqual(waitOutput(["working", nil]).0, BooCLI.Output(text: "t4 exited", status: 1))
        XCTAssertEqual(waitOutput(["working"], timeout: 5).0.status, 124)
        XCTAssertEqual(waitOutput([nil]).0.status, 1, "unknown agent gives up")
    }

    /// `parent` is not a handle: the caller's own row names it.
    func testWaitForParentFollowsTheCallersRow() throws {
        let me = "22222222-2222-2222-2222-222222222222"
        let rows: [[String: Any]] = [
            ["handle": "t2", "tab_id": me, "state": "working", "parent": "t1"],
            ["handle": "t1", "tab_id": "p", "state": "done", "reply": "merged"]
        ]
        var polls = 0
        let output = try BooCLI.wait(
            for: "parent", caller: me, timeout: nil,
            poll: {
                polls += 1
                return [
                    "ok": true, "items": polls == 1 ? [rows[0], rows[1].merging(["state": "working"]) { $1 }] : rows
                ]
            }, sleep: { _ in })
        XCTAssertEqual(output, BooCLI.Output(text: "merged", status: 0))
        let orphan = try BooCLI.wait(
            for: "parent", caller: "nobody", timeout: nil, poll: { ["ok": true, "items": rows] }, sleep: { _ in })
        XCTAssertEqual(orphan.status, 1)
    }

    func testOptionsGoAnywhere() {
        let (_, sent) = run(["read", "--lines", "5", "t3"], reply: ["ok": true, "text": ""])
        XCTAssertEqual(sent.first?["tab_id"] as? String, "t3")
        XCTAssertEqual(sent.first?["lines"] as? Int, 5)
        XCTAssertEqual(run(["read", "t3", "--lines"]).0.status, 2)
        XCTAssertEqual(run(["read", "t3", "--lines=7"], reply: ["ok": true, "text": ""]).1.first?["lines"] as? Int, 7)
        XCTAssertEqual(run(["wait", "t3", "--timeout", "soon"]).0.status, 2)
    }

    func testReadTargetsTheOtherTabNotThisPane() {
        let (output, sent) = run(["read", "t3", "--lines", "20"], reply: ["ok": true, "text": "ready"])
        XCTAssertEqual(output.text, "ready")
        XCTAssertEqual(sent.first?["cmd"] as? String, "get_screen")
        XCTAssertEqual(sent.first?["tab_id"] as? String, "t3")
        XCTAssertEqual(sent.first?["lines"] as? Int, 20)
        XCTAssertNil(sent.first?["pane_id"], "this pane would route the read to the caller")
        XCTAssertEqual(sent.first?["token"] as? String, "tok")
        XCTAssertEqual(run(["read"]).0.status, 2)
    }

    func testTaskCommandsTargetTheTask() {
        let (merged, sent) = run(["merge", "t5"], reply: ["ok": true, "merged": 1, "target": "main"])
        XCTAssertEqual(merged.text, "merged 1 commit into main; its tab and worktree are closed")
        XCTAssertEqual(sent.first?["cmd"] as? String, "merge_task")
        XCTAssertEqual(sent.first?["tab_id"] as? String, "t5")
        XCTAssertEqual(sent.first?["cleanup"] as? Bool, true)
        XCTAssertNil(sent.first?["pane_id"], "this pane would route the merge to the caller")

        XCTAssertEqual(run(["merge", "t5", "--keep"]).1.first?["cleanup"] as? Bool, false)
        let (refused, _) = run(["merge", "t5"], reply: ["ok": false, "error": "boo/x has uncommitted changes."])
        XCTAssertEqual(refused, BooCLI.Output(text: "boo: boo/x has uncommitted changes.", status: 1))

        let (diff, diffSent) = run(
            ["diff", "t5"],
            reply: [
                "ok": true, "files": [["path": "calc.py", "additions": 1, "deletions": 1]],
                "diff": "--- calc.py\n"
            ]
        )
        XCTAssertEqual(diff.text, "+1 -1 calc.py\n\n--- calc.py")
        XCTAssertEqual(diffSent.first?["stat_only"] as? Bool, false)
        XCTAssertEqual(run(["diff", "t5"], reply: ["ok": true, "files": []]).0.text, "no changes")

        let (discarded, discardSent) = run(["discard", "t5"])
        XCTAssertEqual(discarded.text, "discarded t5: its worktree and branch are deleted")
        XCTAssertEqual(discardSent.first?["cmd"] as? String, "discard_task")
        XCTAssertEqual(run(["merge"]).0.status, 2)
    }

    func testWaitTellsBooTheAnswerWasCollected() {
        var sent: [[String: Any]] = []
        let output = BooCLI.run(
            ["wait", "t4"], env: env, cwd: "/w",
            send: { message in
                sent.append(message)
                return ["ok": true, "items": [["handle": "t4", "state": "done", "reply": "hi"]]]
            }, sleep: { _ in })
        XCTAssertEqual(output.text, "hi")
        XCTAssertEqual(sent.last?["cmd"] as? String, "agent_collected")
        XCTAssertEqual(sent.last?["tab_id"] as? String, "t4")
    }
}
