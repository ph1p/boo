import XCTest

@testable import Exterm

final class RemoteSessionTests: XCTestCase {

    func testSSHSessionType() {
        let session = RemoteSessionType.ssh(host: "user@example.com")
        XCTAssertEqual(session.displayName, "user@example.com")
        XCTAssertEqual(session.icon, "globe")
        XCTAssertTrue(session.connectingHint.contains("SSH"))
    }

    func testDockerSessionType() {
        let session = RemoteSessionType.container(target: "my-container", tool: .docker)
        XCTAssertEqual(session.displayName, "my-container")
        XCTAssertEqual(session.icon, "shippingbox")
        XCTAssertTrue(session.connectingHint.contains("docker"))
    }

    func testEquality() {
        let a = RemoteSessionType.ssh(host: "host1")
        let b = RemoteSessionType.ssh(host: "host1")
        let c = RemoteSessionType.ssh(host: "host2")
        let d = RemoteSessionType.container(target: "host1", tool: .docker)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }
}
