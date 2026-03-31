import XCTest

@testable import Boo

final class ContextAnnouncementEngineTests: XCTestCase {

    func testLocalTerminalAnnouncement() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/Users/test/projects/myapp",
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let text = ContextAnnouncementEngine.composeAnnouncement(from: state)
        XCTAssertTrue(text.contains("Local terminal"))
        XCTAssertTrue(text.contains("~/projects/myapp") || text.contains("/Users/test/projects/myapp"))
    }

    func testSSHAnnouncement() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/var/log",
            terminalTitle: "",
            foregroundProcess: "bash",
            remoteSession: .ssh(host: "prod-01"),
            isDockerAvailable: false
        )
        let text = ContextAnnouncementEngine.composeAnnouncement(from: state)
        XCTAssertTrue(text.contains("ssh prod-01"))
        XCTAssertTrue(text.contains("/var/log"))
        XCTAssertTrue(text.contains("bash"))
    }

    func testDockerAnnouncement() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/var/lib/postgresql",
            terminalTitle: "",
            foregroundProcess: "psql",
            remoteSession: .container(target: "postgres", tool: .docker),
            isDockerAvailable: true
        )
        let text = ContextAnnouncementEngine.composeAnnouncement(from: state)
        XCTAssertTrue(text.contains("docker postgres"))
        XCTAssertTrue(text.contains("/var/lib/postgresql"))
        XCTAssertTrue(text.contains("psql"))
    }

    func testEmptyDirectoryAnnouncement() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "",
            terminalTitle: "",
            foregroundProcess: "",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let text = ContextAnnouncementEngine.composeAnnouncement(from: state)
        XCTAssertEqual(text, "Local terminal")
    }

    func testAnnouncementPartsJoinedWithComma() {
        let state = BridgeState(
            paneID: UUID(),
            workspaceID: UUID(),
            workingDirectory: "/tmp",
            terminalTitle: "",
            foregroundProcess: "vim",
            remoteSession: nil,
            isDockerAvailable: false
        )
        let text = ContextAnnouncementEngine.composeAnnouncement(from: state)
        XCTAssertEqual(text, "Local terminal, /tmp, vim")
    }
}
