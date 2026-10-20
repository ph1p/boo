import XCTest

@testable import Boo

final class CommandHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStartAndFinishUsesGhosttyDuration() {
        var history = CommandHistory()
        history.start("make", at: t0)
        XCTAssertEqual(history.last?.isRunning, true)
        history.finish(exitCode: 2, durationNanos: 1_500_000_000, at: t0.addingTimeInterval(9))
        XCTAssertEqual(history.last?.exitCode, 2)
        XCTAssertEqual(history.last?.duration, 1.5)
        XCTAssertEqual(history.last?.finishedAt, t0.addingTimeInterval(9))
        XCTAssertEqual(history.last?.isRunning, false)
    }

    func testFinishWithoutDurationFallsBackToWallClock() {
        var history = CommandHistory()
        history.start("ls", at: t0)
        history.finish(exitCode: -1, durationNanos: 0, at: t0.addingTimeInterval(3))
        XCTAssertNil(history.last?.exitCode)
        XCTAssertEqual(history.last?.duration, 3)
    }

    func testFinishWithoutStartIsIgnored() {
        var history = CommandHistory()
        history.finish(exitCode: 0, durationNanos: 10, at: t0)
        XCTAssertTrue(history.records.isEmpty)

        history.start("a", at: t0)
        history.finish(exitCode: 0, durationNanos: 10, at: t0)
        history.finish(exitCode: 1, durationNanos: 10, at: t0)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.last?.exitCode, 0)
    }

    func testCapsAtLimit() {
        var history = CommandHistory()
        for i in 0..<(CommandHistory.limit + 20) { history.start("cmd \(i)", at: t0) }
        XCTAssertEqual(history.records.count, CommandHistory.limit)
        XCTAssertEqual(history.records.first?.command, "cmd 20")
        XCTAssertEqual(history.last?.command, "cmd \(CommandHistory.limit + 19)")
    }
}
