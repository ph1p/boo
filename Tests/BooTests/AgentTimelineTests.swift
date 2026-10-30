import XCTest

@testable import Boo

final class AgentTimelineTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        var object = object
        object["sessionId"] = object["sessionId"] ?? "s1"
        object["isSidechain"] = object["isSidechain"] ?? false
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func user(_ content: Any, at time: String, extra: [String: Any] = [:]) -> String {
        line(
            [
                "type": "user", "timestamp": "2026-10-17T10:\(time).000Z", "cwd": "/repo",
                "message": ["role": "user", "content": content]
            ]
            .merging(extra) { $1 })
    }

    private func assistant(
        _ id: String, _ content: [[String: Any]], at time: String, model: String = "claude-sonnet-5-5",
        usage: [String: Any] = ["input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000]
    ) -> String {
        line([
            "type": "assistant", "timestamp": "2026-10-17T10:\(time).000Z",
            "message": ["id": id, "model": model, "role": "assistant", "content": content, "usage": usage]
        ])
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private func toolResult(_ id: String, error: Bool = false) -> [[String: Any]] {
        [["type": "tool_result", "tool_use_id": id, "content": "x", "is_error": error]]
    }

    func testTurnsToolsFilesAndReply() {
        let transcript = [
            line(["type": "ai-title", "aiTitle": "Fix login"]),
            user("fix the login bug", at: "00:00", extra: ["origin": ["kind": "human"], "gitBranch": "main"]),
            assistant("m1", [["type": "thinking", "thinking": ""]], at: "00:01"),
            assistant("m1", [toolUse("t1", "Read", ["file_path": "/repo/a.swift"])], at: "00:02"),
            user(toolResult("t1"), at: "00:03"),
            assistant("m2", [toolUse("t2", "Edit", ["file_path": "/repo/a.swift", "old_string": "a"])], at: "00:04"),
            user(toolResult("t2"), at: "00:05"),
            assistant(
                "m3", [toolUse("t3", "Bash", ["command": "swift test\n--verbose", "description": "Run"])], at: "00:06"),
            user(toolResult("t3", error: true), at: "00:07"),
            assistant("m4", [["type": "text", "text": "Fixed it."]], at: "00:30"),
            user(
                "<task-notification>\n<task-id>x</task-id>", at: "00:31",
                extra: ["origin": ["kind": "task-notification"]]),
            user("caveat", at: "00:31", extra: ["isMeta": true])
        ].joined(separator: "\n")

        let timeline = AgentTimeline.parse(transcript)
        XCTAssertEqual(timeline.title, "Fix login")
        XCTAssertEqual(timeline.sessionID, "s1")
        XCTAssertEqual(timeline.branch, "main")
        XCTAssertEqual(timeline.cwd, "/repo")
        XCTAssertEqual(timeline.models, ["claude-sonnet-5-5"])
        XCTAssertEqual(timeline.turns.count, 1, "task notifications and meta lines are not prompts")
        let turn = timeline.turns[0]
        XCTAssertEqual(turn.prompt, "fix the login bug")
        XCTAssertEqual(turn.tools.map(\.name), ["Read", "Edit", "Bash"])
        XCTAssertEqual(turn.tools[2].summary, "swift test", "first line of the command")
        XCTAssertEqual(turn.tools.map(\.failures), [0, 0, 1])
        XCTAssertEqual(turn.reply, "Fixed it.")
        XCTAssertEqual(turn.duration, 31)
        XCTAssertEqual(timeline.files.map(\.path), ["/repo/a.swift"], "only edits count as touched")
        XCTAssertEqual(turn.context, 1010)
    }

    func testUsageCountsEachMessageOnceAndEstimatesCost() {
        let usage: [String: Any] = [
            "input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000,
            "cache_creation_input_tokens": 2_000_000,
            "cache_creation": ["ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 1_000_000]
        ]
        let transcript = [
            user("go", at: "00:00"),
            assistant("m1", [["type": "thinking", "thinking": ""]], at: "00:01", usage: usage),
            assistant("m1", [["type": "text", "text": "ok"]], at: "00:02", usage: usage)
        ].joined(separator: "\n")
        let timeline = AgentTimeline.parse(transcript)
        XCTAssertEqual(timeline.usage.output, 1_000_000, "split message lines repeat their usage")
        XCTAssertEqual(timeline.usage.cacheWrite1h, 1_000_000)
        XCTAssertEqual(timeline.usage.cacheWrite5m, 1_000_000)
        // sonnet 5.5: $2 in, 10 out, 0.2 read, 2.5 5m write, 4 1h write
        XCTAssertEqual(timeline.cost, 18.7, accuracy: 0.001)
        XCTAssertFalse(timeline.costIsExact)
        XCTAssertEqual(timeline.turns[0].cost, 18.7, accuracy: 0.001)
    }

    func testExactCostOnlyWhenNothingFollowedIt() {
        let base = [
            user("one", at: "00:00"),
            assistant("m1", [["type": "text", "text": "a"]], at: "00:01"),
            user("two", at: "00:02"),
            assistant("m2", [["type": "text", "text": "b"]], at: "00:03"),
            line(["type": "cost-state", "totalCostUSD": 3.0])
        ]
        let ended = AgentTimeline.parse(base.joined(separator: "\n"))
        XCTAssertTrue(ended.costIsExact)
        XCTAssertEqual(ended.cost, 3.0)
        XCTAssertEqual(ended.turns.map(\.cost).reduce(0, +), 3.0, accuracy: 0.0001, "turns share the exact total")
        XCTAssertEqual(ended.turns[0].cost, 1.5, accuracy: 0.0001)

        let resumed = AgentTimeline.parse(
            (base + [user("three", at: "00:04"), assistant("m3", [], at: "00:05")]).joined(separator: "\n"))
        XCTAssertFalse(resumed.costIsExact)
        XCTAssertEqual(resumed.turns.count, 3)
    }

    func testRepeatedCallsFoldIntoALoop() {
        var lines = [user("make it pass", at: "00:00")]
        for index in 0..<4 {
            lines.append(
                assistant("m\(index)", [toolUse("t\(index)", "Bash", ["command": "pnpm test"])], at: "00:0\(index + 1)")
            )
            lines.append(user(toolResult("t\(index)", error: true), at: "00:0\(index + 1)"))
        }
        lines.append(assistant("m9", [toolUse("t9", "Bash", ["command": "pnpm lint"])], at: "00:09"))
        let timeline = AgentTimeline.parse(lines.joined(separator: "\n"))
        let tools = timeline.turns[0].tools
        XCTAssertEqual(tools.map(\.count), [4, 1])
        XCTAssertEqual(tools[0].failures, 4)
        XCTAssertTrue(tools[0].isLoop)
        XCTAssertFalse(tools[1].isLoop)
        XCTAssertEqual(timeline.loopCount, 1)
        XCTAssertEqual(timeline.toolCount, 5)
    }

    func testCommandsCompactionAndInterruptions() {
        let command =
            "<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args>PR 4</command-args>"
        let clear =
            "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
        let transcript = [
            user(clear, at: "00:00"),
            user("<local-command-stdout></local-command-stdout>", at: "00:00"),
            user(command, at: "00:01"),
            assistant("m1", [["type": "text", "text": "Looks good"]], at: "00:02"),
            user([["type": "text", "text": "[Request interrupted by user]"]], at: "00:03"),
            user("summary", at: "00:04", extra: ["isCompactSummary": true]),
            user([["type": "text", "text": "continue"], ["type": "image", "source": [:]]], at: "00:05")
        ].joined(separator: "\n")
        let turns = AgentTimeline.parse(transcript).turns
        XCTAssertEqual(turns.map(\.kind), [.command, .compacted, .prompt], "/clear did nothing and is dropped")
        XCTAssertEqual(turns[0].prompt, "/review PR 4")
        XCTAssertTrue(turns[0].interrupted)
        XCTAssertEqual(turns[2].prompt, "continue")
        XCTAssertEqual(turns.map(\.id), [0, 1, 2])
    }

    func testSidechainLinesAreSkippedAndSubagentsAddTokens() {
        let transcript = [
            user("go", at: "00:00"),
            user("sub prompt", at: "00:01", extra: ["isSidechain": true]),
            assistant("m1", [], at: "00:02")
        ].joined(separator: "\n")
        let parser = AgentTimeline.Parser()
        parser.consume(Data((transcript + "\n").utf8))
        XCTAssertEqual(parser.timeline.turns.count, 1)
        let sub = assistant("s1", [], at: "00:03", usage: ["input_tokens": 0, "output_tokens": 1_000_000])
        let line = Data((sub + "\n").utf8)
        parser.consumeSubagent("a.jsonl", line.prefix(10))
        XCTAssertEqual(parser.timeline.subagentUsage.output, 0, "a partial line waits for the rest")
        parser.consumeSubagent("a.jsonl", line.dropFirst(10))
        XCTAssertEqual(parser.timeline.subagentUsage.output, 1_000_000)
        parser.resetSubagent("a.jsonl")
        parser.consumeSubagent("a.jsonl", line)
        XCTAssertEqual(parser.timeline.subagentUsage.output, 1_000_000, "reading a file again replaces it")
        XCTAssertEqual(
            parser.timeline.cost,
            AgentTimeline.estimatedCost(of: parser.timeline.usage, model: "claude-sonnet-5-5") + 10, accuracy: 0.001)
    }

    func testIncrementalConsumeKeepsPartialLines() {
        let full = [user("first", at: "00:00"), user("second", at: "00:01")].joined(separator: "\n") + "\n"
        let bytes = Array(full.utf8)
        let parser = AgentTimeline.Parser()
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            parser.consume(Data(bytes[chunk..<min(chunk + 7, bytes.count)]))
        }
        XCTAssertEqual(parser.timeline.turns.map(\.prompt), ["first", "second"])
    }

    func testPastedBlocksCollapse() {
        let text = "fix this\n\n<pasted_content id=\"ab\">\nline 1\nline 2\n</pasted_content>\nthanks"
        XCTAssertEqual(AgentTimeline.Parser.collapsePastes(in: text), "fix this\n\n[pasted 2 lines]\nthanks")
        XCTAssertEqual(
            AgentTimeline.Parser.collapsePastes(in: "<pasted_content id=\"x\">one</pasted_content>"), "[pasted 1 line]")
    }

    func testToolSummaries() {
        typealias P = AgentTimeline.Parser
        XCTAssertEqual(P.tool(name: "Grep", input: ["pattern": "foo", "path": "src"]).summary, "foo  in src")
        XCTAssertEqual(P.tool(name: "WebFetch", input: ["url": "https://x.dev"]).summary, "https://x.dev")
        XCTAssertEqual(P.tool(name: "NotebookEdit", input: ["notebook_path": "/n.ipynb"]).file, "/n.ipynb")
        XCTAssertNil(P.tool(name: "Read", input: ["file_path": "/a"]).file)
        XCTAssertEqual(P.tool(name: "mcp__boo__split_pane", input: ["direction": "right", "n": 1]).summary, "right")
        XCTAssertEqual(P.tool(name: "Bash", input: ["command": String(repeating: "a", count: 300)]).summary.count, 240)
    }

    func testTranscriptLookupAndStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("abc/subagents"), withIntermediateDirectories: true)
        let url = project.appendingPathComponent("abc.jsonl")
        try Data((user("hello", at: "00:00") + "\n").utf8).write(to: url)

        XCTAssertEqual(AgentTimeline.transcriptURL(sessionID: "abc", claudeDirectory: root)?.path, url.path)
        XCTAssertNil(AgentTimeline.transcriptURL(sessionID: "nope", claudeDirectory: root))
        XCTAssertNil(AgentTimeline.transcriptURL(sessionID: "../x", claudeDirectory: root))

        let store = AgentTimelineStore()
        XCTAssertEqual(store.load(url)?.turns.map(\.prompt), ["hello"])
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((user("again", at: "00:01") + "\n").utf8))
        try handle.close()
        try Data((assistant("s", [], at: "00:02") + "\n").utf8).write(
            to: project.appendingPathComponent("abc/subagents/agent-1.jsonl"))
        let grown = store.load(url)
        XCTAssertEqual(grown?.turns.map(\.prompt), ["hello", "again"])
        XCTAssertEqual(grown?.subagentUsage.output, 100)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(store.load(url))
    }

    @MainActor func testSocketSummary() throws {
        var lines = [user("first", at: "00:00"), user("make it pass", at: "00:01")]
        for index in 0..<3 {
            lines.append(
                assistant("m\(index)", [toolUse("t\(index)", "Bash", ["command": "pnpm test"])], at: "00:0\(index + 2)")
            )
            lines.append(user(toolResult("t\(index)", error: true), at: "00:0\(index + 2)"))
        }
        let summary = AgentTimeline.parse(lines.joined(separator: "\n")).serialize(turns: 1)
        XCTAssertEqual(summary["prompts"] as? Int, 2)
        XCTAssertEqual(summary["loops"] as? Int, 1)
        let turns = try XCTUnwrap(summary["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["prompt"] as? String }, ["make it pass"])
        XCTAssertEqual(turns[0]["failed"] as? Int, 3)
        XCTAssertEqual((turns[0]["loops"] as? [[String: Any]])?.first?["count"] as? Int, 3)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: summary))

        var reply: [String: Any]?
        AgentInbox.shared.timeline([:]) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, false, "missing ids are refused without a transcript read")
    }

    func testCompactDuration() {
        XCTAssertEqual(DurationFormat.compact(42), "42s")
        XCTAssertEqual(DurationFormat.compact(125), "2m 5s")
        XCTAssertEqual(DurationFormat.compact(3720), "1h 2m")
    }
}
