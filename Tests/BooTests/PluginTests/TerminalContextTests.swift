import XCTest

@testable import Boo

final class TerminalContextTests: XCTestCase {

    func testBuildFromBridgeState() {
        let paneID = UUID()
        let state = BridgeState(
            paneID: paneID,
            workspaceID: UUID(),
            workingDirectory: "/Users/test/project",
            terminalTitle: "vim",
            foregroundProcess: "vim",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let ctx = TerminalContext.build(
            from: state,
            gitBranch: "main",
            gitRepoRoot: "/Users/test/project",
            paneCount: 3,
            tabCount: 2
        )

        XCTAssertEqual(ctx.terminalID, paneID)
        XCTAssertEqual(ctx.cwd, "/Users/test/project")
        XCTAssertNil(ctx.remoteSession)
        XCTAssertFalse(ctx.isRemote)
        XCTAssertEqual(ctx.processName, "vim")
        XCTAssertEqual(ctx.paneCount, 3)
        XCTAssertEqual(ctx.tabCount, 2)
        XCTAssertEqual(ctx.gitContext?.branch, "main")
        XCTAssertEqual(ctx.gitContext?.repoRoot, "/Users/test/project")
        XCTAssertEqual(ctx.environmentLabel, "local")
    }

    func testBuildWithSSH() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/var/log",
            terminalTitle: "",
            foregroundProcess: "bash",
            remoteSession: .ssh(host: "prod-01"),
            isDockerAvailable: false
        )
        let ctx = TerminalContext.build(from: state)

        XCTAssertTrue(ctx.isRemote)
        XCTAssertEqual(ctx.environmentLabel, "ssh: prod-01")
        if case .ssh(let host, _) = ctx.remoteSession {
            XCTAssertEqual(host, "prod-01")
        } else {
            XCTFail("Expected SSH session")
        }
    }

    func testBuildWithDocker() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/var/lib/postgresql",
            terminalTitle: "",
            foregroundProcess: "psql",
            remoteSession: .container(target: "postgres", tool: .docker),
            isDockerAvailable: true
        )
        let ctx = TerminalContext.build(from: state)

        XCTAssertTrue(ctx.isRemote)
        XCTAssertEqual(ctx.environmentLabel, "docker: postgres")
    }

    func testBuildWithoutGit() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/tmp",
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let ctx = TerminalContext.build(from: state)

        XCTAssertNil(ctx.gitContext)
    }

    func testEquality() {
        let id = UUID()
        let state = BridgeState(
            paneID: id,
            workspaceID: UUID(),
            workingDirectory: "/tmp",
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let ctx1 = TerminalContext.build(from: state, gitBranch: "main", gitRepoRoot: "/tmp")
        let ctx2 = TerminalContext.build(from: state, gitBranch: "main", gitRepoRoot: "/tmp")

        XCTAssertEqual(ctx1, ctx2)
    }
}
