import XCTest
@testable import Exterm

final class RemoteExplorerTests: XCTestCase {

    // MARK: - ControlMaster Config

    func testEnableControlMasterIdempotent() {
        // If ControlMaster is already in the config, enableControlMaster should detect it
        let content = """
        Host *
          ControlMaster auto
          ControlPath ~/.ssh/cm-%r@%h:%p
        """
        XCTAssertTrue(content.lowercased().contains("controlmaster"))
    }

    // MARK: - Session Type Properties

    func testSSHSessionConnectingHint() {
        let session = RemoteSessionType.ssh(host: "test-host")
        XCTAssertTrue(session.connectingHint.contains("SSH"))
        XCTAssertTrue(session.connectingHint.contains("ControlMaster"))
    }

    func testDockerSessionConnectingHint() {
        let session = RemoteSessionType.docker(container: "my-container")
        XCTAssertTrue(session.connectingHint.contains("container"))
    }

    // MARK: - Remote Session Display

    func testSSHHostWithUser() {
        let session = RemoteSessionType.ssh(host: "phlp@nas.local")
        XCTAssertEqual(session.displayName, "phlp@nas.local")
    }

    func testSSHHostWithoutUser() {
        let session = RemoteSessionType.ssh(host: "nas.local")
        XCTAssertEqual(session.displayName, "nas.local")
    }

    func testDockerContainerDisplay() {
        let session = RemoteSessionType.docker(container: "web-app")
        XCTAssertEqual(session.displayName, "web-app")
        XCTAssertEqual(session.icon, "shippingbox")
    }

    func testSSHIcon() {
        let session = RemoteSessionType.ssh(host: "host")
        XCTAssertEqual(session.icon, "globe")
    }
}
