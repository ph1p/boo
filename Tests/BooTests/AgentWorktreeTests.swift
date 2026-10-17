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
    }
}
