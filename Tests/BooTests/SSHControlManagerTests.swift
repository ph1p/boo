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
}
