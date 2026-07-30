import XCTest

@testable import Boo

final class SSHControlManagerTests: XCTestCase {

    override func tearDown() {
        SSHControlManager.shared.clearTestState()
        super.tearDown()
    }

    func testSocketFilePathDeterministic() {
        let a = SSHControlManager.socketFilePath(for: "myhost")
        let b = SSHControlManager.socketFilePath(for: "myhost")
        XCTAssertEqual(a, b)
    }

    func testSocketFilePathSanitizesSpecialChars() {
        let path = SSHControlManager.socketFilePath(for: "user@host:22")
        XCTAssertFalse(path.contains("@"))
        XCTAssertFalse(path.contains(":"))
        XCTAssertTrue(path.contains("user-host-22"))
    }

    func testConnectionStateNilForUnknown() {
        XCTAssertNil(SSHControlManager.shared.connectionState(for: "never-seen"))
    }

    func testClearTestStateRemovesAll() {
        SSHControlManager.shared.setTestState(alias: "a", state: .ready)
        SSHControlManager.shared.setTestState(alias: "b", state: .connecting)
        SSHControlManager.shared.clearTestState()
        XCTAssertNil(SSHControlManager.shared.connectionState(for: "a"))
        XCTAssertNil(SSHControlManager.shared.connectionState(for: "b"))
    }

    func testSocketPathNilWhenNotReady() {
        SSHControlManager.shared.setTestState(alias: "testhost", state: .connecting)
        XCTAssertNil(SSHControlManager.shared.socketPath(for: "testhost"))

        SSHControlManager.shared.setTestState(alias: "testhost", state: .failed)
        XCTAssertNil(SSHControlManager.shared.socketPath(for: "testhost"))
    }

    func testSocketPathReturnedWhenReady() {
        SSHControlManager.shared.setTestState(alias: "testhost", state: .ready)
        let path = SSHControlManager.shared.socketPath(for: "testhost")
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("testhost"))
    }

    // MARK: - Socket path collisions

    /// Sanitizing alone maps every non-alphanumeric to "-", so aliases that differ
    /// only in punctuation collapsed onto one socket and shared a connection.
    func testDistinctAliasesGetDistinctSockets() {
        let cases = [
            ("host.example.com", "host-example-com"),
            ("user@host", "user-host"),
            ("host:22", "host-22")
        ]
        for (a, b) in cases {
            XCTAssertNotEqual(
                SSHControlManager.socketFilePath(for: a),
                SSHControlManager.socketFilePath(for: b),
                "\(a) and \(b) must not share a control socket")
        }
    }

    func testSocketFileNameIsLengthBounded() {
        let long = String(repeating: "verylonghostname", count: 20) + "@example.com"
        let name = (SSHControlManager.socketFilePath(for: long) as NSString).lastPathComponent
        // sockaddr_un caps the whole path at ~104 bytes on macOS.
        XCTAssertLessThan(name.utf8.count, 64)
    }

    // MARK: - Refcounting

    /// A master is shared between panes on the same host. One pane going away must
    /// not tear the connection out from under the others.
    func testMasterSurvivesUntilLastOwnerReleases() {
        let alias = "shared-host"
        let paneA = UUID()
        let paneB = UUID()

        SSHControlManager.shared.acquireWithoutConnecting(alias: alias, owner: paneA)
        SSHControlManager.shared.acquireWithoutConnecting(alias: alias, owner: paneB)
        SSHControlManager.shared.setTestState(alias: alias, state: .ready, isManaged: false)
        XCTAssertEqual(SSHControlManager.shared.testOwnerCount(alias: alias), 2)

        SSHControlManager.shared.release(alias: alias, owner: paneA)
        SSHControlManager.shared.drainForTesting()
        XCTAssertEqual(SSHControlManager.shared.testOwnerCount(alias: alias), 1)
        XCTAssertNotNil(
            SSHControlManager.shared.connectionState(for: alias),
            "master must stay up while another pane still uses it")

        SSHControlManager.shared.release(alias: alias, owner: paneB)
        SSHControlManager.shared.drainForTesting()
        XCTAssertEqual(SSHControlManager.shared.testOwnerCount(alias: alias), 0)
        XCTAssertNil(
            SSHControlManager.shared.connectionState(for: alias),
            "master must be torn down once the last owner releases")
    }

    func testDuplicateAcquireDoesNotInflateOwnerCount() {
        let alias = "dup-host"
        let pane = UUID()
        SSHControlManager.shared.acquireWithoutConnecting(alias: alias, owner: pane)
        SSHControlManager.shared.acquireWithoutConnecting(alias: alias, owner: pane)
        XCTAssertEqual(SSHControlManager.shared.testOwnerCount(alias: alias), 1)

        SSHControlManager.shared.setTestState(alias: alias, state: .ready, isManaged: false)
        SSHControlManager.shared.release(alias: alias, owner: pane)
        SSHControlManager.shared.drainForTesting()
        XCTAssertNil(
            SSHControlManager.shared.connectionState(for: alias),
            "a single release must fully drop a doubly-acquired alias")
    }

    func testReleaseByUnknownOwnerDoesNotDropOthers() {
        let alias = "other-host"
        let pane = UUID()
        SSHControlManager.shared.acquireWithoutConnecting(alias: alias, owner: pane)
        SSHControlManager.shared.setTestState(alias: alias, state: .ready, isManaged: false)

        SSHControlManager.shared.release(alias: alias, owner: UUID())
        SSHControlManager.shared.drainForTesting()
        XCTAssertEqual(SSHControlManager.shared.testOwnerCount(alias: alias), 1)
        XCTAssertNotNil(SSHControlManager.shared.connectionState(for: alias))
    }
}
