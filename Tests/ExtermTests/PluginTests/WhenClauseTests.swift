import XCTest

@testable import Exterm

final class WhenClauseParserTests: XCTestCase {

    func testEmptyExpression() throws {
        let node = try WhenClauseParser.parse("")
        XCTAssertEqual(node, .alwaysTrue)
    }

    func testSimpleVariable() throws {
        let node = try WhenClauseParser.parse("git.active")
        XCTAssertEqual(node, .variable("git.active"))
    }

    func testNotOperator() throws {
        let node = try WhenClauseParser.parse("!remote")
        XCTAssertEqual(node, .not(.variable("remote")))
    }

    func testAndOperator() throws {
        let node = try WhenClauseParser.parse("git.active && env.ssh")
        XCTAssertEqual(node, .and(.variable("git.active"), .variable("env.ssh")))
    }

    func testOrOperator() throws {
        let node = try WhenClauseParser.parse("env.ssh || env.docker")
        XCTAssertEqual(node, .or(.variable("env.ssh"), .variable("env.docker")))
    }

    func testEquality() throws {
        let node = try WhenClauseParser.parse("process.name == 'kubectl'")
        XCTAssertEqual(node, .equals(.variable("process.name"), .stringLiteral("kubectl")))
    }

    func testNotEquals() throws {
        let node = try WhenClauseParser.parse("process.name != 'zsh'")
        XCTAssertEqual(node, .notEquals(.variable("process.name"), .stringLiteral("zsh")))
    }

    func testComplexExpression() throws {
        let node = try WhenClauseParser.parse("env.ssh && process.name == 'kubectl'")
        XCTAssertEqual(
            node,
            .and(
                .variable("env.ssh"),
                .equals(.variable("process.name"), .stringLiteral("kubectl"))
            ))
    }

    func testParentheses() throws {
        let node = try WhenClauseParser.parse("(env.ssh || env.docker) && git.active")
        XCTAssertEqual(
            node,
            .and(
                .or(.variable("env.ssh"), .variable("env.docker")),
                .variable("git.active")
            ))
    }

    func testPrecedence() throws {
        // && binds tighter than ||
        let node = try WhenClauseParser.parse("a || b && c")
        XCTAssertEqual(node, .or(.variable("a"), .and(.variable("b"), .variable("c"))))
    }

    func testDoubleQuotedString() throws {
        let node = try WhenClauseParser.parse("process.name == \"vim\"")
        XCTAssertEqual(node, .equals(.variable("process.name"), .stringLiteral("vim")))
    }

    func testParseErrorUnterminatedString() {
        XCTAssertThrowsError(try WhenClauseParser.parse("process.name == 'unterminated")) { error in
            XCTAssertTrue("\(error)".contains("Unterminated"))
        }
    }

    func testParseErrorUnmatchedParen() {
        XCTAssertThrowsError(try WhenClauseParser.parse("(env.ssh && git")) { error in
            XCTAssertTrue("\(error)".contains("')'"))
        }
    }

    func testParseErrorTrailingToken() {
        XCTAssertThrowsError(try WhenClauseParser.parse("git.active )")) { error in
            XCTAssertTrue("\(error)".contains("Unexpected"))
        }
    }
}

final class WhenClauseEvaluatorTests: XCTestCase {

    private func makeContext(
        remote: RemoteSessionType? = nil,
        gitBranch: String? = nil,
        processName: String = ""
    ) -> TerminalContext {
        let git: TerminalContext.GitContext?
        if let branch = gitBranch {
            git = TerminalContext.GitContext(
                branch: branch, repoRoot: "/repo", isDirty: false, changedFileCount: 0, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil)
        } else {
            git = nil
        }
        return TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: remote,
            gitContext: git,
            processName: processName,
            paneCount: 1,
            tabCount: 1
        )
    }

    func testAlwaysTrue() throws {
        let node = try WhenClauseParser.parse("")
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext()))
    }

    func testEnvLocal() throws {
        let node = try WhenClauseParser.parse("env.local")
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .ssh(host: "server"))))
    }

    func testEnvSSH() throws {
        let node = try WhenClauseParser.parse("env.ssh")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .ssh(host: "server"))))
        XCTAssertFalse(
            WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .container(target: "app", tool: .docker))))
    }

    func testEnvDocker() throws {
        let node = try WhenClauseParser.parse("env.docker")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertTrue(
            WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .container(target: "app", tool: .docker))))
    }

    func testRemote() throws {
        let node = try WhenClauseParser.parse("remote")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .ssh(host: "s"))))
    }

    func testNotRemote() throws {
        let node = try WhenClauseParser.parse("!remote")
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .ssh(host: "s"))))
    }

    func testGitActive() throws {
        let node = try WhenClauseParser.parse("git.active")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(gitBranch: "main")))
    }

    func testGitShorthand() throws {
        let node = try WhenClauseParser.parse("git")
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(gitBranch: "main")))
    }

    func testProcessNameEquals() throws {
        let node = try WhenClauseParser.parse("process.name == 'kubectl'")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext(processName: "vim")))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(processName: "kubectl")))
    }

    func testComplexWhenClause() throws {
        let node = try WhenClauseParser.parse("env.ssh && process.name == 'kubectl'")
        let local = makeContext(processName: "kubectl")
        let sshKubectl = makeContext(remote: .ssh(host: "s"), processName: "kubectl")
        let sshVim = makeContext(remote: .ssh(host: "s"), processName: "vim")

        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: local))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: sshKubectl))
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: sshVim))
    }

    func testOrExpression() throws {
        let node = try WhenClauseParser.parse("env.ssh || env.docker")
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: makeContext()))
        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .ssh(host: "s"))))
        XCTAssertTrue(
            WhenClauseEvaluator.evaluate(node, context: makeContext(remote: .container(target: "c", tool: .docker))))
    }

    func testGroupedExpression() throws {
        let node = try WhenClauseParser.parse("(env.ssh || env.docker) && git.active")
        let sshGit = makeContext(remote: .ssh(host: "s"), gitBranch: "main")
        let sshNoGit = makeContext(remote: .ssh(host: "s"))
        let localGit = makeContext(gitBranch: "main")

        XCTAssertTrue(WhenClauseEvaluator.evaluate(node, context: sshGit))
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: sshNoGit))
        XCTAssertFalse(WhenClauseEvaluator.evaluate(node, context: localGit))
    }
}
