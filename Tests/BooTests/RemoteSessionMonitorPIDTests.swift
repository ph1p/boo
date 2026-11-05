import XCTest

@testable import Boo

/// Tests that RemoteSessionMonitor reports per-pane shell PIDs.
final class RemoteSessionMonitorPIDTests: XCTestCase {

    // MARK: - onShellPIDUpdated callback

    func testOnShellPIDUpdatedFiresOnTrack() {
        let monitor = RemoteSessionMonitor()
        let pane = UUID()
        var receivedPaneID: UUID?
        var receivedPID: pid_t?
        let exp = expectation(description: "callback")
        monitor.onShellPIDUpdated = { paneID, pid, _ in
            receivedPaneID = paneID
            receivedPID = pid
            exp.fulfill()
        }
        monitor.track(paneID: pane, shellPID: 5555)
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(receivedPaneID, pane)
        XCTAssertEqual(receivedPID, 5555)
    }
}

/// Tests for the ClaimedDirectChildren registry that prevents two GhosttyViews
/// from claiming the same login/shell process during concurrent creation.
@MainActor
final class ClaimedDirectChildrenTests: XCTestCase {

    override func setUp() async throws {
        // Release any lingering claims between tests
        ClaimedDirectChildren.release(9001)
        ClaimedDirectChildren.release(9002)
        ClaimedDirectChildren.release(9003)
    }

    func testClaimFailsForAlreadyClaimedPID() {
        XCTAssertTrue(ClaimedDirectChildren.claim(9001))
        XCTAssertFalse(ClaimedDirectChildren.claim(9001), "Second claim must fail")
        ClaimedDirectChildren.release(9001)
    }

    func testReleaseAllowsReclaim() {
        XCTAssertTrue(ClaimedDirectChildren.claim(9001))
        ClaimedDirectChildren.release(9001)
        XCTAssertTrue(ClaimedDirectChildren.claim(9001), "After release, claim must succeed again")
        ClaimedDirectChildren.release(9001)
    }

    func testDistinctPIDsCanBothBeClaimed() {
        XCTAssertTrue(ClaimedDirectChildren.claim(9001))
        XCTAssertTrue(ClaimedDirectChildren.claim(9002))
        ClaimedDirectChildren.release(9001)
        ClaimedDirectChildren.release(9002)
    }

    /// The sorted() in discoverShellPID ensures deterministic winner selection.
    /// Verify that when pane A takes the lowest PID, pane B must take the next one.
    func testDeterministicWinnerIsLowestPID() {
        let candidates: [pid_t] = [9003, 9001, 9002]
        let sorted = candidates.sorted()

        // Pane A picks first available (lowest)
        let paneAWinner = sorted.first { ClaimedDirectChildren.claim($0) }
        // Pane B picks next available
        let paneBWinner = sorted.first { ClaimedDirectChildren.claim($0) }

        XCTAssertEqual(paneAWinner, 9001, "Pane A must get lowest PID")
        XCTAssertEqual(paneBWinner, 9002, "Pane B must get next lowest PID")

        ClaimedDirectChildren.release(9001)
        ClaimedDirectChildren.release(9002)
    }
}
