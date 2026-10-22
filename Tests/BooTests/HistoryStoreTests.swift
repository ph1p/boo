import XCTest

@testable import Boo

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: HistoryStore!
    private let workspace = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = HistoryStore(path: dir.appendingPathComponent("history.db").path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func add(
        _ cmd: String, cwd: String = "/p", exit: Int32? = 0, host: String? = nil, workspace: UUID? = nil,
        hoursAgo: Double = 1
    ) {
        store.insert(
            FinishedCommand(
                command: cmd, exitCode: exit, duration: 0.25, startedAt: now.addingTimeInterval(-hoursAgo * 3600),
                cwd: cwd, host: host, workspaceID: workspace ?? self.workspace, paneID: UUID(), tabID: UUID()))
    }

    private func search(_ filter: HistoryFilter) -> [String] {
        store.searchSync(filter, now: now).map(\.command)
    }

    func testRecentDistinctCommandsWhenEmpty() {
        add("ls", hoursAgo: 3)
        add("make", hoursAgo: 2)
        add("ls", hoursAgo: 1)
        let entries = store.searchSync(HistoryFilter(), now: now)
        XCTAssertEqual(entries.map(\.command), ["ls", "make"])
        XCTAssertEqual(entries.first?.count, 2)
        XCTAssertEqual(entries.first?.durationMs, 250)
    }

    func testFullTextPrefixMatch() {
        add("git commit -m wip")
        add("git status")
        add("make test")
        XCTAssertEqual(Set(search(HistoryFilter(text: "git"))), ["git commit -m wip", "git status"])
        XCTAssertEqual(search(HistoryFilter(text: "comm wi")), ["git commit -m wip"])
    }

    func testFuzzyFallback() {
        add("git commit -m wip")
        add("make test")
        XCTAssertEqual(search(HistoryFilter(text: "gcm")), ["git commit -m wip"])
    }

    func testQuotesInQueryAreSafe() {
        add(#"echo "hi""#)
        XCTAssertEqual(search(HistoryFilter(text: #""hi"#)), [#"echo "hi""#])
        XCTAssertEqual(search(HistoryFilter(text: "AND OR NOT")), [])
    }

    func testFilters() {
        let other = UUID()
        add("a", exit: 1)
        add("b", exit: 0, host: "srv", workspace: other)
        add("c", cwd: "/q", exit: nil)
        XCTAssertEqual(search(HistoryFilter(failedOnly: true)), ["a"])
        XCTAssertEqual(search(HistoryFilter(workspaceID: other)), ["b"])
        XCTAssertEqual(search(HistoryFilter(host: .some("srv"))), ["b"])
        XCTAssertEqual(Set(search(HistoryFilter(host: .some(nil)))), ["a", "c"])
        XCTAssertEqual(search(HistoryFilter(cwd: "/q")), ["c"])
    }

    func testSameDirectoryRanksHigher() {
        add("npm run dev", cwd: "/web", hoursAgo: 5)
        add("npm run build", cwd: "/api", hoursAgo: 1)
        XCTAssertEqual(search(HistoryFilter(text: "npm", preferredCwd: "/web")).first, "npm run dev")
        XCTAssertEqual(search(HistoryFilter(text: "npm")).first, "npm run build")
    }

    func testDeleteClearPrune() {
        add("old", hoursAgo: 24 * 400)
        add("keep")
        add("drop")
        let done = expectation(description: "delete")
        store.delete(command: "drop") { done.fulfill() }
        wait(for: [done], timeout: 2)
        store.prune(olderThanDays: 365, now: now)
        XCTAssertEqual(search(HistoryFilter()), ["keep"])
        XCTAssertEqual(search(HistoryFilter(text: "drop")), [])
        let cleared = expectation(description: "clear")
        store.clear { cleared.fulfill() }
        wait(for: [cleared], timeout: 2)
        XCTAssertEqual(search(HistoryFilter()), [])
    }

    func testIgnorePattern() throws {
        let regex = try NSRegularExpression(pattern: AppSettings.defaultHistoryIgnorePattern)
        XCTAssertTrue(HistoryRecorder.isIgnored(" secret-cmd", by: regex))
        XCTAssertTrue(HistoryRecorder.isIgnored("curl -H API_KEY=abc", by: regex))
        XCTAssertTrue(HistoryRecorder.isIgnored("   ", by: nil))
        XCTAssertFalse(HistoryRecorder.isIgnored("ls -la", by: regex))
    }

    func testFTSQueryQuoting() {
        XCTAssertEqual(HistoryStore.ftsQuery(#"a "b"#), #""a"* """b"*"#)
    }
}
