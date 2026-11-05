import XCTest

@testable import Boo

final class TerminalContextTests: XCTestCase {
    private func context(remote: RemoteSessionType?) -> TerminalContext {
        TerminalContext(
            terminalID: UUID(),
            cwd: "/var/log",
            remoteSession: remote,
            gitContext: nil,
            processName: "bash",
            paneCount: 1,
            tabCount: 1
        )
    }

    func testLocalEnvironmentLabel() {
        let ctx = context(remote: nil)
        XCTAssertFalse(ctx.isRemote)
        XCTAssertEqual(ctx.environmentLabel, "local")
    }

    func testSSHEnvironmentLabel() {
        let ctx = context(remote: .ssh(host: "prod-01"))
        XCTAssertTrue(ctx.isRemote)
        XCTAssertEqual(ctx.environmentLabel, "ssh: prod-01")
    }

    func testDockerEnvironmentLabel() {
        let ctx = context(remote: .container(target: "postgres", tool: .docker))
        XCTAssertTrue(ctx.isRemote)
        XCTAssertEqual(ctx.environmentLabel, "docker: postgres")
    }
}
