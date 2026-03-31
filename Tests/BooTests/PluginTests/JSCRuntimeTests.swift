import XCTest

@testable import Boo

final class JSCRuntimeTests: XCTestCase {

    private let runtime = JSCRuntime()

    private func makeContext(
        cwd: String = "/tmp",
        gitBranch: String? = nil,
        remote: RemoteSessionType? = nil,
        process: String = ""
    ) -> TerminalContext {
        let git: TerminalContext.GitContext?
        if let branch = gitBranch {
            git = TerminalContext.GitContext(
                branch: branch, repoRoot: "/repo", isDirty: true, changedFileCount: 2, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil)
        } else {
            git = nil
        }
        return TerminalContext(
            terminalID: UUID(),
            cwd: cwd,
            remoteSession: remote,
            gitContext: git,
            processName: process,
            paneCount: 1,
            tabCount: 1
        )
    }

    func testBasicTransform() throws {
        let source = """
            function transform(ctx) {
                return JSON.stringify({ type: "label", text: "Hello from " + ctx.cwd });
            }
            """
        let result = try runtime.execute(source: source, context: makeContext(cwd: "/home/user"))
        XCTAssertTrue(result.contains("Hello from /home/user"), "Got: \(result)")
    }

    func testContextAccess() throws {
        let source = """
            function transform(ctx) {
                return JSON.stringify({ type: "label", text: ctx.envType + ":" + ctx.cwd });
            }
            """
        let result = try runtime.execute(source: source, context: makeContext())
        XCTAssertTrue(result.contains("local:/tmp"), "Got: \(result)")
    }

    func testGitContextAccess() throws {
        let source = """
            function transform(ctx) {
                if (ctx.git) {
                    return JSON.stringify({ type: "label", text: ctx.git.branch });
                }
                return JSON.stringify({ type: "label", text: "no git" });
            }
            """
        let withGit = try runtime.execute(source: source, context: makeContext(gitBranch: "feature"))
        XCTAssertTrue(withGit.contains("feature"), "Got: \(withGit)")

        let noGit = try runtime.execute(source: source, context: makeContext())
        XCTAssertTrue(noGit.contains("no git"), "Got: \(noGit)")
    }

    func testRemoteContextAccess() throws {
        let source = """
            function transform(ctx) {
                return JSON.stringify({ type: "label", text: ctx.envType + ":" + (ctx.remoteHost || "none") });
            }
            """
        let ssh = try runtime.execute(source: source, context: makeContext(remote: .ssh(host: "server")))
        XCTAssertTrue(ssh.contains("ssh:server"), "Got: \(ssh)")
    }

    func testMissingFunction() {
        let source = "var x = 42;"
        XCTAssertThrowsError(try runtime.execute(source: source, context: makeContext())) { error in
            XCTAssertTrue("\(error)".contains("not found"))
        }
    }

    func testJSSyntaxError() {
        let source = "function transform(ctx) { return {{invalid; }"
        XCTAssertThrowsError(try runtime.execute(source: source, context: makeContext())) { error in
            XCTAssertTrue("\(error)".lowercased().contains("error"))
        }
    }

    func testArrayReturn() throws {
        let source = """
            function transform(ctx) {
                return JSON.stringify([
                    { type: "label", text: "first" },
                    { type: "label", text: "second" }
                ]);
            }
            """
        let result = try runtime.execute(source: source, context: makeContext())
        XCTAssertTrue(result.contains("first"), "Got: \(result)")
        XCTAssertTrue(result.contains("second"), "Got: \(result)")
    }
}
