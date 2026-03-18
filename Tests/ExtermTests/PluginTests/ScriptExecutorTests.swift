import XCTest
@testable import Exterm

final class ScriptExecutorTests: XCTestCase {

    func testBuildEnvironmentLocal() {
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/test/project",
            remoteSession: nil,
            gitContext: TerminalContext.GitContext(branch: "main", repoRoot: "/Users/test/project", isDirty: true, changedFileCount: 3),
            processName: "vim",
            paneCount: 2,
            tabCount: 1
        )
        let env = ScriptExecutor.buildEnvironment(from: ctx)

        XCTAssertEqual(env["EXTERM_CWD"], "/Users/test/project")
        XCTAssertEqual(env["EXTERM_ENV_TYPE"], "local")
        XCTAssertEqual(env["EXTERM_GIT_BRANCH"], "main")
        XCTAssertEqual(env["EXTERM_GIT_DIRTY"], "true")
        XCTAssertEqual(env["EXTERM_GIT_CHANGED_COUNT"], "3")
        XCTAssertEqual(env["EXTERM_PROCESS"], "vim")
        XCTAssertEqual(env["EXTERM_PANE_COUNT"], "2")
        XCTAssertNil(env["EXTERM_REMOTE_HOST"])
    }

    func testBuildEnvironmentSSH() {
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/var/log",
            remoteSession: .ssh(host: "prod-01"),
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let env = ScriptExecutor.buildEnvironment(from: ctx)

        XCTAssertEqual(env["EXTERM_ENV_TYPE"], "ssh")
        XCTAssertEqual(env["EXTERM_REMOTE_HOST"], "prod-01")
        XCTAssertNil(env["EXTERM_GIT_BRANCH"])
    }

    func testBuildEnvironmentDocker() {
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/",
            remoteSession: .docker(container: "postgres"),
            gitContext: nil,
            processName: "psql",
            paneCount: 1,
            tabCount: 1
        )
        let env = ScriptExecutor.buildEnvironment(from: ctx)

        XCTAssertEqual(env["EXTERM_ENV_TYPE"], "docker")
        XCTAssertEqual(env["EXTERM_REMOTE_HOST"], "postgres")
        XCTAssertEqual(env["EXTERM_PROCESS"], "psql")
    }
}
