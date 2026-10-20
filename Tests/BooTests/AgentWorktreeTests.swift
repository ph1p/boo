import XCTest

@testable import Boo

final class AgentWorktreeTests: XCTestCase {
    private var sandbox: String!
    private var repo: String!
    private var root: String!

    override func setUpWithError() throws {
        // Resolved: /var → /private/var, or git's absolute paths won't compare equal.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
            .replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)
        sandbox = (base as NSString).appendingPathComponent("boo-worktree-\(UUID().uuidString)")
        repo = (sandbox as NSString).appendingPathComponent("myrepo")
        root = (sandbox as NSString).appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
        try write("a.txt", "one\n", in: repo)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    @discardableResult
    private func git(_ args: String..., in dir: String? = nil) throws -> String {
        try AgentWorktree.git(args, in: dir ?? repo)
    }

    private func write(_ file: String, _ text: String, in dir: String) throws {
        try text.write(toFile: (dir as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func commit(_ file: String, _ text: String, in dir: String) throws {
        try write(file, text, in: dir)
        try git("add", ".", in: dir)
        try git("commit", "-q", "-m", "change \(file)", in: dir)
    }

    func testSlug() {
        XCTAssertEqual(AgentWorktree.slug("Fix the login bug!"), "fix-the-login-bug")
        XCTAssertEqual(AgentWorktree.slug("  --Ünïcode ok--  "), "n-code-ok")
        XCTAssertEqual(AgentWorktree.slug("!!!"), "task")
        XCTAssertLessThanOrEqual(AgentWorktree.slug(String(repeating: "abc ", count: 30)).count, 40)
        XCTAssertFalse(AgentWorktree.slug(String(repeating: "abc ", count: 30)).hasSuffix("-"))
    }

    func testCreateInfoAndSuffix() throws {
        let info = try AgentWorktree.create(repo: repo, name: "Fix login", root: root)
        XCTAssertEqual(info.branch, "boo/fix-login")
        XCTAssertEqual(info.path, "\(root!)/myrepo/fix-login")
        XCTAssertTrue(AgentWorktree.looksLikeWorktree(info.path))
        XCTAssertFalse(AgentWorktree.looksLikeWorktree(repo))
        XCTAssertNil(AgentWorktree.info(for: repo), "the main checkout is not a task")
        XCTAssertEqual(AgentWorktree.info(for: info.path), info)

        let second = try AgentWorktree.create(repo: info.path, name: "Fix login", root: root)
        XCTAssertEqual(second.branch, "boo/fix-login-2", "taken names get a suffix")
        XCTAssertEqual(second.mainRoot, repo, "a task started from a task hangs off the main checkout")
    }

    func testStatusAndMerge() throws {
        let info = try AgentWorktree.create(repo: repo, name: "feature", root: root)
        XCTAssertEqual(AgentWorktree.status(of: info), .init(isDirty: false, ahead: 0, target: "main"))

        try write("b.txt", "new\n", in: info.path)
        XCTAssertTrue(AgentWorktree.status(of: info).isDirty)
        XCTAssertThrowsError(try AgentWorktree.merge(info), "uncommitted work is not merged")

        try git("add", ".", in: info.path)
        try git("commit", "-q", "-m", "add b", in: info.path)
        XCTAssertEqual(AgentWorktree.status(of: info), .init(isDirty: false, ahead: 1, target: "main"))

        try AgentWorktree.merge(info)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo!)/b.txt"))
        XCTAssertEqual(AgentWorktree.status(of: info).ahead, 0)

        try AgentWorktree.remove(info, deleteBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path))
        XCTAssertThrowsError(try git("rev-parse", "--verify", "-q", "refs/heads/boo/feature"))
    }

    func testConflictingMergeIsAborted() throws {
        let info = try AgentWorktree.create(repo: repo, name: "clash", root: root)
        try commit("a.txt", "theirs\n", in: info.path)
        try commit("a.txt", "ours\n", in: repo)

        XCTAssertThrowsError(try AgentWorktree.merge(info))
        XCTAssertEqual(try git("status", "--porcelain"), "", "main checkout is left clean")
        XCTAssertEqual(try String(contentsOfFile: "\(repo!)/a.txt", encoding: .utf8), "ours\n")
    }

    func testCreateFromBase() throws {
        try git("branch", "old")
        try commit("a.txt", "two\n", in: repo)
        let info = try AgentWorktree.create(repo: repo, name: "from old", base: "old", root: root)
        XCTAssertEqual(try String(contentsOfFile: "\(info.path)/a.txt", encoding: .utf8), "one\n")
        XCTAssertEqual(AgentWorktree.mergeCheck(of: info).behind, 1)
        XCTAssertThrowsError(try AgentWorktree.create(repo: repo, name: "x", base: "nope", root: root))
    }

    func testMergeCheckBlockers() throws {
        let info = try AgentWorktree.create(repo: repo, name: "check", root: root)
        XCTAssertEqual(AgentWorktree.mergeCheck(of: info).blocker, "nothing_to_merge")

        try commit("b.txt", "new\n", in: info.path)
        var check = AgentWorktree.mergeCheck(of: info)
        XCTAssertNil(check.blocker)
        XCTAssertEqual(check.conflicts, [])
        XCTAssertEqual(check.status.ahead, 1)

        try write("a.txt", "local edit\n", in: repo)
        check = AgentWorktree.mergeCheck(of: info)
        XCTAssertTrue(check.targetDirty)
        XCTAssertEqual(check.blocker, "target_dirty")
        XCTAssertThrowsError(try AgentWorktree.merge(info), "never merges over the user's uncommitted work")
        XCTAssertEqual(try String(contentsOfFile: "\(repo!)/a.txt", encoding: .utf8), "local edit\n")
        try git("checkout", "a.txt")

        try write("untracked.txt", "x\n", in: repo)
        XCTAssertFalse(AgentWorktree.mergeCheck(of: info).targetDirty, "untracked files don't block")

        try write("c.txt", "wip\n", in: info.path)
        XCTAssertEqual(AgentWorktree.mergeCheck(of: info).blocker, "dirty")
    }

    func testMergeCheckFindsConflicts() throws {
        let info = try AgentWorktree.create(repo: repo, name: "clash", root: root)
        try commit("a.txt", "theirs\n", in: info.path)
        try commit("a.txt", "ours\n", in: repo)
        let check = AgentWorktree.mergeCheck(of: info)
        XCTAssertEqual(check.conflicts, ["a.txt"])
        XCTAssertEqual(check.behind, 1)
        XCTAssertEqual(check.blocker, "conflicts")
        XCTAssertEqual(try git("status", "--porcelain"), "", "checking touches no checkout")
    }

    func testCreateOutsideGitFails() {
        XCTAssertThrowsError(try AgentWorktree.create(repo: sandbox, name: "x", root: root))
    }

    @MainActor func testAgentCommand() {
        typealias C = MainWindowController
        XCTAssertEqual(C.agentTaskCommand(kind: .claudeCode, prompt: " "), "claude")
        XCTAssertEqual(C.agentTaskCommand(kind: .claudeCode, prompt: "fix it"), "claude 'fix it'")
        XCTAssertEqual(C.agentTaskCommand(kind: .codex, prompt: "don't"), "codex 'don'\\''t'")
        XCTAssertEqual(C.agentTaskCommand(kind: .openCode, prompt: "go"), "opencode --prompt 'go'")
        XCTAssertEqual(C.agentTaskCommand(kind: .openCode, prompt: ""), "opencode")
        XCTAssertEqual(
            C.agentTaskCommand(kind: .claudeCode, prompt: "go", model: "opus"), "claude --model 'opus' 'go'")
        XCTAssertEqual(C.agentTaskCommand(kind: .openCode, prompt: "", model: " "), "opencode")
    }

    func testTaskDiffTextAndBlockerHints() {
        typealias C = MainWindowController
        var file = AgentReview.FileDiff(path: "a.txt")
        file.hunks = [
            .init(
                header: "@@ -1 +1 @@",
                lines: [
                    .init(kind: .removed, oldLine: 1, newLine: nil, text: "one"),
                    .init(kind: .added, oldLine: nil, newLine: 1, text: "two")
                ])
        ]
        XCTAssertEqual(C.unifiedText([file]), "--- a.txt (modified)\n@@ -1 +1 @@\n-one\n+two\n")

        let info = AgentWorktree.Info(path: "/wt/x", mainRoot: "/repo", branch: "boo/x")
        let conflicts = AgentWorktree.MergeCheck(
            status: .init(isDirty: false, ahead: 2, target: "main"), behind: 1, targetDirty: false,
            conflicts: ["a.txt"])
        XCTAssertEqual(
            C.blockerMessage(conflicts, info), "boo/x conflicts with main in a.txt. Ask its agent to rebase onto main.")
        let ready = AgentWorktree.MergeCheck(
            status: .init(isDirty: false, ahead: 2, target: "main"), behind: 0, targetDirty: false, conflicts: [])
        XCTAssertNil(C.blockerMessage(ready, info))
    }
}
