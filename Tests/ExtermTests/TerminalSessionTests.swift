import XCTest
@testable import Exterm

final class TerminalSessionTests: XCTestCase {

    func testSessionEndCallbackChain() {
        var sessionEndedCalled = false

        let pty = PTYProcess()
        var onSessionEnded: (() -> Void)?
        onSessionEnded = { sessionEndedCalled = true }

        pty.onExited = {
            onSessionEnded?()
        }

        // Simulate process exit
        pty.onExited?()

        XCTAssertTrue(sessionEndedCalled)
    }

    func testSessionEndCallbackNotCalledBeforeExit() {
        var called = false
        let pty = PTYProcess()
        pty.onExited = { called = true }

        // Don't trigger exit
        XCTAssertFalse(called)
    }

    func testOnSessionEndedNilByDefault() {
        let pty = PTYProcess()
        XCTAssertNil(pty.onExited)
    }
}
