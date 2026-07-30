import XCTest

@testable import Boo

/// `git worktree list --porcelain` parsing. Replaced hand-rolled `.git` file parsing
/// that missed non-`.claude/worktrees` worktrees, detached HEADs and packed refs.
final class WorktreeParsingTests: XCTestCase {

    private let root = "/repo"

    func testSkipsMainWorktree() {
        let output = """
            worktree /repo
            HEAD abc1234567890
            branch refs/heads/main

            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertTrue(result.isEmpty, "the main working tree is not a linked worktree")
    }

    /// The old implementation only looked under `.claude/worktrees`, so a worktree
    /// created with plain `git worktree add ../feature` was invisible.
    func testFindsWorktreeOutsideClaudeDirectory() {
        let output = """
            worktree /repo
            HEAD aaaaaaaaaaaa
            branch refs/heads/main

            worktree /elsewhere/feature
            HEAD bbbbbbbbbbbb
            branch refs/heads/feature-x

            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "/elsewhere/feature")
        XCTAssertEqual(result[0].branch, "feature-x")
        XCTAssertEqual(result[0].headCommit, "bbbbbbb")
    }

    /// Detached HEAD has no `branch` line — the old parser returned nil and the
    /// worktree fell back to a synthetic "worktree-<slug>" name.
    func testDetachedHeadReportsShortSHA() {
        let output = """
            worktree /repo

            worktree /repo/wt/detached
            HEAD ccccccccccccdddd
            detached

            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].headCommit, "ccccccc")
        XCTAssertEqual(result[0].branch, "detached @ ccccccc")
    }

    func testBareRepoEntryIsSkipped() {
        let output = """
            worktree /repo/bare
            bare

            worktree /repo/wt/a
            HEAD eeeeeeeeeeee
            branch refs/heads/a

            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertEqual(result.map(\.path), ["/repo/wt/a"])
    }

    /// Output may lack the trailing blank line; the final record must still emit.
    func testFinalRecordWithoutTrailingBlankLine() {
        let output = """
            worktree /repo/wt/last
            HEAD ffffffffffff
            branch refs/heads/last
            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertEqual(result.map(\.branch), ["last"])
    }

    func testEmptyOutputYieldsNoWorktrees() {
        XCTAssertTrue(AgentsPlugin.parseWorktreePorcelain("", projectRoot: root).isEmpty)
    }

    /// Branch names may contain slashes; only the `refs/heads/` prefix is stripped.
    func testBranchNameWithSlashes() {
        let output = """
            worktree /repo/wt/f
            HEAD 111111111111
            branch refs/heads/feature/nested/name

            """
        let result = AgentsPlugin.parseWorktreePorcelain(output, projectRoot: root)
        XCTAssertEqual(result.map(\.branch), ["feature/nested/name"])
    }
}
