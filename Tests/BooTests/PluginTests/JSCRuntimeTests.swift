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

    func testReadFileCannotEscapeCwdViaDotDot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsc-sandbox-\(UUID().uuidString)")
        let inner = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try "top-secret".write(to: secret, atomically: true, encoding: .utf8)

        let source = """
            function transform(ctx) {
                var leaked = readFile("../secret.txt");
                return JSON.stringify({ type: "label", text: String(leaked) });
            }
            """
        let result = try runtime.execute(source: source, context: makeContext(cwd: inner.path))
        XCTAssertFalse(result.contains("top-secret"), "Traversal escaped cwd: \(result)")
    }

    func testReadFileCannotEscapeCwdViaSymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsc-symlink-\(UUID().uuidString)")
        let inner = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try "top-secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("link.txt"), withDestinationURL: secret)

        let source = """
            function transform(ctx) {
                var leaked = readFile("link.txt");
                return JSON.stringify({ type: "label", text: String(leaked) });
            }
            """
        let result = try runtime.execute(source: source, context: makeContext(cwd: inner.path))
        XCTAssertFalse(result.contains("top-secret"), "Symlink escaped cwd: \(result)")
    }

    func testReadFileInsideCwdStillWorks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsc-inside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello-inside".write(
            to: dir.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)

        let source = """
            function transform(ctx) {
                return JSON.stringify({ type: "label", text: String(readFile("ok.txt")) });
            }
            """
        let result = try runtime.execute(source: source, context: makeContext(cwd: dir.path))
        XCTAssertTrue(result.contains("hello-inside"), "Got: \(result)")
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
