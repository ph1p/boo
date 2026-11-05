import XCTest

@testable import Boo

final class AgentCostLedgerTests: XCTestCase {
    private typealias Scanner = AgentCostLedger.Scanner

    func testModelNames() {
        XCTAssertEqual(AgentCostSummary.modelName("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(AgentCostSummary.modelName("claude-sonnet-4-20250514"), "Sonnet 4")
        XCTAssertEqual(AgentCostSummary.modelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(AgentCostSummary.modelName("claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(AgentCostSummary.modelName("claude-opus-4-6[1m]"), "Opus 4.6")
        XCTAssertEqual(AgentCostSummary.modelName("gpt-5"), "gpt-5")
    }

    func testProjectNamesDisambiguateSameFolderName() {
        let names = AgentCostSummary.projectNames(["/p/boo", "/w/boo", "/p/web", ""])
        XCTAssertEqual(names["/p/boo"], "p/boo")
        XCTAssertEqual(names["/w/boo"], "w/boo")
        XCTAssertEqual(names["/p/web"], "web")
        XCTAssertEqual(names[""], "Unknown")
    }

    func testSummarySplitsByPeriodProjectModelAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000_000)  // 2001-09-09 01:46 UTC
        let today = calendar.startOfDay(for: now)
        func record(
            _ daysAgo: Int, _ project: String, _ model: String, _ cost: Double, subagent: Bool = false
        )
            -> AgentCostRecord
        {
            AgentCostRecord(
                time: today.addingTimeInterval(Double(-daysAgo) * 86_400 + 60), model: model, project: project,
                session: "s\(daysAgo)", subagent: subagent, cost: cost)
        }
        let records = [
            record(0, "/p/boo", "claude-opus-4-5", 2),
            record(0, "/p/boo", "claude-haiku-4-5", 1, subagent: true),
            record(1, "/p/web", "claude-opus-4-5-20251101", 4),
            record(10, "/p/web", "claude-sonnet-4-5", 8)
        ]

        let day = AgentCostSummary(records, days: 1, now: now, calendar: calendar)
        XCTAssertEqual(day.total, 3, accuracy: 0.001)
        XCTAssertEqual(day.subagents, 1, accuracy: 0.001)
        XCTAssertEqual(day.sessions, 1)
        XCTAssertEqual(day.days.count, 1)

        let week = AgentCostSummary(records, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.total, 7, accuracy: 0.001)
        XCTAssertEqual(week.projects.map(\.name), ["web", "boo"])
        XCTAssertEqual(week.models.map(\.name), ["Opus 4.5", "Haiku 4.5"], "IDs with and without a date merge")
        XCTAssertEqual(week.models.first?.cost ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.start, today)
        XCTAssertEqual(week.days.last?.cost ?? 0, 3, accuracy: 0.001)

        let month = AgentCostSummary(records, days: 30, now: now, calendar: calendar)
        XCTAssertEqual(month.total, 15, accuracy: 0.001)
        XCTAssertEqual(month.sessions, 3)
    }

    func testReadKeepsLastUsagePerMessage() {
        var state = Scanner.FileState()
        for line in [
            assistant("m1", output: 10, cwd: "/p/boo"),
            assistant("m1", output: 1000),
            assistant("m2", model: "<synthetic>", output: 50),
            #"{"type":"user","message":{"content":"hi"}}"#
        ] {
            Scanner.read(Data(line.utf8), into: &state)
        }
        XCTAssertEqual(state.project, "/p/boo")
        XCTAssertEqual(Array(state.messages.keys), ["m1"], "synthetic messages cost nothing")
        let expected = AgentTimeline.estimatedCost(
            of: AgentTimeline.Usage(output: 1000), model: "claude-opus-4-5")
        XCTAssertEqual(state.messages["m1"]?.cost ?? 0, expected, accuracy: 1e-9)
    }

    func testRecordsCountRepeatedMessagesOnce() {
        let message = Scanner.Message(time: Date(), model: "claude-opus-4-5", cost: 1)
        var main = Scanner.FileState()
        main.project = "/p/boo"
        main.messages = ["m1": message, "m2": message]
        var resumed = Scanner.FileState()
        resumed.messages = ["m2": message, "m3": message]
        let records = Scanner.records([
            "/x/-p-boo/a.jsonl": main, "/x/-p-boo/b.jsonl": resumed,
            "/x/-p-boo/a/subagents/agent-1.jsonl": Scanner.FileState(messages: ["m4": message])
        ])
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.filter(\.subagent).map(\.session), ["a"])
    }

    func testScanReadsOnlyAppendedLines() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = folder.appendingPathComponent("-p-boo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = project.appendingPathComponent("s1.jsonl")
        try (assistant("m1", output: 10) + "\n" + assistant("m2", output: 10)).write(
            to: file, atomically: true, encoding: .utf8)

        let scanner = Scanner(projects: folder, cache: nil)
        let now = Date()
        XCTAssertEqual(scanner.scan(now: now).count, 1, "an unfinished last line waits")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + assistant("m3", output: 10) + "\n").utf8))
        try handle.close()
        let records = scanner.scan(now: now)
        XCTAssertEqual(Set(records.map(\.session)), ["s1"])
        XCTAssertEqual(records.count, 3)
    }

    private func assistant(_ id: String, model: String = "claude-opus-4-5", output: Int, cwd: String? = nil) -> String {
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))"\#(cwdField),"#
            + #""message":{"id":"\#(id)","model":"\#(model)","usage":{"output_tokens":\#(output)}}}"#
    }
}
