import XCTest

@testable import Boo

/// Tests that RemoteSessionMonitor correctly tracks per-pane shell PIDs
/// and that otherTrackedPIDs(excluding:) returns only PIDs from other panes.
final class RemoteSessionMonitorPIDTests: XCTestCase {

    // MARK: - otherTrackedPIDs

    func testOtherTrackedPIDsEmptyWhenNoPanesTracked() {
        let monitor = RemoteSessionMonitor()
        XCTAssertTrue(monitor.otherTrackedPIDs(excluding: UUID()).isEmpty)
    }

    func testOtherTrackedPIDsExcludesRequestingPane() {
        let monitor = RemoteSessionMonitor()
        let pane = UUID()
        let exp = expectation(description: "track")
        monitor.onShellPIDUpdated = { _, _, _ in exp.fulfill() }
        monitor.track(paneID: pane, shellPID: 1001)
        wait(for: [exp], timeout: 1)

        XCTAssertTrue(monitor.otherTrackedPIDs(excluding: pane).isEmpty)
    }

    func testOtherTrackedPIDsIncludesOtherPanes() {
        let monitor = RemoteSessionMonitor()
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        let exp = expectation(description: "tracked 3")
        exp.expectedFulfillmentCount = 3
        monitor.onShellPIDUpdated = { _, _, _ in exp.fulfill() }
        monitor.track(paneID: paneA, shellPID: 1001)
        monitor.track(paneID: paneB, shellPID: 1002)
        monitor.track(paneID: paneC, shellPID: 1003)
        wait(for: [exp], timeout: 1)

        let excludingA = monitor.otherTrackedPIDs(excluding: paneA)
        XCTAssertFalse(excludingA.contains(1001))
        XCTAssertTrue(excludingA.contains(1002))
        XCTAssertTrue(excludingA.contains(1003))
        XCTAssertEqual(excludingA.count, 2)
    }

    func testOtherTrackedPIDsAfterPIDUpdate() {
        let monitor = RemoteSessionMonitor()
        let paneA = UUID()
        let paneB = UUID()
        let exp = expectation(description: "tracked 2")
        exp.expectedFulfillmentCount = 2
        monitor.onShellPIDUpdated = { _, _, _ in exp.fulfill() }
        monitor.track(paneID: paneA, shellPID: 1001)
        monitor.track(paneID: paneB, shellPID: 1002)
        wait(for: [exp], timeout: 1)

        monitor.updateShellPID(paneID: paneA, shellPID: 9999)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 1)

        let excludingB = monitor.otherTrackedPIDs(excluding: paneB)
        XCTAssertTrue(excludingB.contains(9999))
        XCTAssertFalse(excludingB.contains(1001))
        XCTAssertFalse(excludingB.contains(1002))
    }

    func testOtherTrackedPIDsAfterUntrack() {
        let monitor = RemoteSessionMonitor()
        let paneA = UUID()
        let paneB = UUID()
        let exp = expectation(description: "tracked 2")
        exp.expectedFulfillmentCount = 2
        monitor.onShellPIDUpdated = { _, _, _ in exp.fulfill() }
        monitor.track(paneID: paneA, shellPID: 1001)
        monitor.track(paneID: paneB, shellPID: 1002)
        wait(for: [exp], timeout: 1)

        monitor.untrack(paneID: paneA)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 1)

        XCTAssertTrue(monitor.otherTrackedPIDs(excluding: paneB).isEmpty)
    }

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

    func testClaimSucceedsForUnclaimedPID() {
        XCTAssertTrue(ClaimedDirectChildren.claim(9001))
        ClaimedDirectChildren.release(9001)
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

    /// Simulates two panes racing to discover the same direct child PID.
    /// Only the first claim should win; the second must be rejected.
    func testTwoPanesRacingForSameDirectChild() {
        let sharedDirectChild: pid_t = 9001

        // Pane A claims first
        let paneAClaimed = ClaimedDirectChildren.claim(sharedDirectChild)
        // Pane B tries to claim the same PID
        let paneBClaimed = ClaimedDirectChildren.claim(sharedDirectChild)

        XCTAssertTrue(paneAClaimed, "First claimer must win")
        XCTAssertFalse(paneBClaimed, "Second claimer must be rejected")

        ClaimedDirectChildren.release(sharedDirectChild)
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
