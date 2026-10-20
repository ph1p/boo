import XCTest

@testable import Boo

final class TerminalProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStateMachine() {
        var p = TerminalProgress.applying(.set, percent: 40, to: nil, now: t0)
        XCTAssertEqual(p, TerminalProgress(state: .normal, percent: 40, updatedAt: t0))

        // Error and pause without a value keep the last percent.
        p = TerminalProgress.applying(.error, percent: -1, to: p, now: t0)
        XCTAssertEqual(p?.state, .error)
        XCTAssertEqual(p?.percent, 40)
        p = TerminalProgress.applying(.pause, percent: -1, to: p, now: t0)
        XCTAssertEqual(p?.state, .paused)
        XCTAssertEqual(p?.percent, 40)
        p = TerminalProgress.applying(.pause, percent: 70, to: p, now: t0)
        XCTAssertEqual(p?.percent, 70)

        p = TerminalProgress.applying(.indeterminate, percent: -1, to: p, now: t0)
        XCTAssertEqual(p?.state, .indeterminate)
        XCTAssertNil(p?.percent)
        XCTAssertEqual(p?.fraction, 1)

        XCTAssertNil(TerminalProgress.applying(.remove, percent: -1, to: p, now: t0))
    }

    func testSetClampsAndDefaults() {
        XCTAssertEqual(TerminalProgress.applying(.set, percent: 150, to: nil, now: t0)?.percent, 100)
        XCTAssertEqual(TerminalProgress.applying(.set, percent: -1, to: nil, now: t0)?.percent, 0)
        XCTAssertEqual(TerminalProgress.applying(.set, percent: 25, to: nil, now: t0)?.fraction, 0.25)
    }

    func testStaleAfterFifteenMinutes() {
        let p = TerminalProgress(state: .normal, percent: 10, updatedAt: t0)
        XCTAssertFalse(p.isStale(now: t0.addingTimeInterval(14 * 60)))
        XCTAssertTrue(p.isStale(now: t0.addingTimeInterval(15 * 60)))
        XCTAssertNil(TerminalProgress.summary([p], now: t0.addingTimeInterval(16 * 60)))
    }

    func testSummaryPrefersErrorThenFurthest() {
        let a = TerminalProgress(state: .normal, percent: 30, updatedAt: t0)
        let b = TerminalProgress(state: .normal, percent: 80, updatedAt: t0)
        let busy = TerminalProgress(state: .indeterminate, percent: nil, updatedAt: t0)
        let failed = TerminalProgress(state: .error, percent: 10, updatedAt: t0)
        XCTAssertEqual(TerminalProgress.summary([a, busy, b], now: t0), b)
        XCTAssertEqual(TerminalProgress.summary([busy], now: t0), busy)
        XCTAssertEqual(TerminalProgress.summary([a, failed, b], now: t0), failed)
        XCTAssertNil(TerminalProgress.summary([], now: t0))
    }

    func testPaneSetProgressReportsChanges() {
        let pane = Pane()
        pane.addTab(workingDirectory: "/tmp")
        let p = TerminalProgress(state: .normal, percent: 10, updatedAt: t0)
        XCTAssertTrue(pane.setProgress(p, at: 0))
        // Same state and percent, newer timestamp: no redraw needed.
        XCTAssertFalse(pane.setProgress(TerminalProgress(state: .normal, percent: 10, updatedAt: Date()), at: 0))
        XCTAssertTrue(pane.setProgress(nil, at: 0))
        XCTAssertFalse(pane.setProgress(p, at: 5))
    }
}
