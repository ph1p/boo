import XCTest

@testable import Boo

@MainActor
final class AgentTaskStatusTests: XCTestCase {
    private let info = AgentWorktree.Info(path: "/w/fix", mainRoot: "/repo", branch: "boo/fix")

    private func check(
        dirty: Bool = false, ahead: Int = 2, target: String? = "main", targetDirty: Bool = false,
        conflicts: [String]? = []
    ) -> AgentWorktree.MergeCheck {
        AgentWorktree.MergeCheck(
            status: AgentWorktree.Status(isDirty: dirty, ahead: ahead, target: target), behind: 0,
            targetDirty: targetDirty, conflicts: conflicts)
    }

    func testCleanBranchReadsReady() {
        let summary = AgentTaskStatus.summary(check: check(), files: 5, info: info)
        XCTAssertEqual(summary.text, "2 commits · 5 files · merges into main")
        XCTAssertEqual(summary.tone, .ready)
        XCTAssertEqual(summary.branch, "boo/fix")
    }

    func testSingularCounts() {
        let summary = AgentTaskStatus.summary(check: check(ahead: 1), files: 1, info: info)
        XCTAssertEqual(summary.text, "1 commit · 1 file · merges into main")
    }

    func testConflictsBlock() {
        let summary = AgentTaskStatus.summary(check: check(conflicts: ["a", "b"]), files: 3, info: info)
        XCTAssertEqual(summary.text, "2 commits · 3 files · 2 conflicts with main")
        XCTAssertEqual(summary.tone, .blocked)
    }

    func testBlockersExplainThemselves() {
        XCTAssertEqual(
            AgentTaskStatus.summary(check: check(dirty: true, ahead: 0), files: 0, info: info).text,
            "uncommitted changes")
        let target = AgentTaskStatus.summary(check: check(targetDirty: true), files: 2, info: info)
        XCTAssertEqual(target.text, "2 commits · 2 files · main checkout has changes")
        XCTAssertEqual(target.tone, .blocked)
        let empty = AgentTaskStatus.summary(check: check(ahead: 0), files: 0, info: info)
        XCTAssertEqual(empty.text, "no commits yet")
        XCTAssertEqual(empty.tone, .neutral)
        XCTAssertEqual(AgentTaskStatus.summary(check: check(ahead: 0, target: nil), files: 0, info: info).text, "")
    }

    // MARK: - Tab badge

    func testTabBadgeShowsWorkingAndWaitingOnly() {
        let theme = AppSettings.shared.theme
        let inbox = AgentInbox()
        inbox.locate = { _ in nil }
        let tab = UUID()
        XCTAssertNil(PaneView.agentBadgeColor(for: nil, theme: theme))

        inbox.apply(event: "prompt", tabID: tab)
        XCTAssertNotNil(PaneView.agentBadgeColor(for: inbox.items[tab], theme: theme), "working")

        inbox.apply(event: "permission", tabID: tab, message: "needs permission")
        XCTAssertEqual(PaneView.agentBadgeColor(for: inbox.items[tab], theme: theme), theme.warning)

        inbox.apply(event: "stop", tabID: tab)
        if inbox.items[tab]?.needsAttention == true {
            XCTAssertNotNil(PaneView.agentBadgeColor(for: inbox.items[tab], theme: theme), "unread answer")
        }
        inbox.markSeen(tabID: tab)
        XCTAssertNil(PaneView.agentBadgeColor(for: inbox.items[tab], theme: theme), "a read answer stays quiet")
    }
}
