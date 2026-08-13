import XCTest

@testable import Boo

@MainActor
final class DebouncerTests: XCTestCase {

    /// A burst of triggers must produce exactly one call — that coalescing is the whole
    /// reason the FS-event and git-status paths own one of these.
    func testBurstOfTriggersFiresOnce() {
        let debouncer = Debouncer(delay: 0.05)
        var calls = 0
        let done = expectation(description: "fired")

        for _ in 0..<10 {
            debouncer.schedule {
                calls += 1
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(calls, 1, "A burst must collapse into a single call")
    }

    /// Only the newest block runs — an earlier trigger's closure is discarded, not queued.
    func testLatestBlockWins() {
        let debouncer = Debouncer(delay: 0.05)
        var fired: [String] = []
        let done = expectation(description: "fired")

        debouncer.schedule { fired.append("stale") }
        debouncer.schedule {
            fired.append("fresh")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fired, ["fresh"], "The superseded block must not run")
    }

    func testCancelPreventsTheCall() {
        let debouncer = Debouncer(delay: 0.05)
        var calls = 0

        debouncer.schedule { calls += 1 }
        XCTAssertTrue(debouncer.isPending)
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)

        let settled = expectation(description: "past the delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(calls, 0, "A cancelled call must never fire")
    }

    func testCancelWithNothingPendingIsSafe() {
        let debouncer = Debouncer(delay: 0.05)
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)
    }

    /// Two triggers sharing one debouncer coalesce even when they ask for different
    /// delays — GitPlugin relies on this so a `.git/` event and a work-tree event in the
    /// same burst produce one status refresh, not two.
    func testPerCallDelayOverrideStillCoalesces() {
        let debouncer = Debouncer(delay: 5)
        var calls = 0
        let done = expectation(description: "fired")

        debouncer.schedule(delay: 0.4) { calls += 1 }
        debouncer.schedule(delay: 0.05) {
            calls += 1
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(calls, 1, "The override must replace the pending call, not add one")
    }

    /// `isPending` must clear once the block has run, so a later `cancel()` on a spent
    /// debouncer is not mistaken for a live one.
    func testIsPendingClearsAfterFiring() {
        let debouncer = Debouncer(delay: 0.05)
        let done = expectation(description: "fired")
        debouncer.schedule { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(debouncer.isPending, "A fired debouncer must not report work pending")
    }
}
