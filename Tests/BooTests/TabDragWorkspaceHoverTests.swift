import XCTest

@testable import Boo

/// Tests for TabDragCoordinator's workspace hover behaviour:
/// hovering over a workspace pill for long enough fires onWorkspaceHover,
/// moving away cancels the timer, and cleanup resets all state.
final class TabDragWorkspaceHoverTests: XCTestCase {

    private var coordinator: TabDragCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = TabDragCoordinator()
    }

    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }

    // MARK: - workspacePillFrames callback

    func testWorkspacePillFramesNilByDefault() {
        // No frames closure installed — checkWorkspaceHover should be a no-op
        XCTAssertNil(coordinator.workspacePillFrames)
    }

    func testWorkspacePillFramesCanBeSet() {
        let frames: [(index: Int, screenFrame: NSRect)] = [
            (0, NSRect(x: 100, y: 100, width: 80, height: 24)),
            (1, NSRect(x: 190, y: 100, width: 80, height: 24))
        ]
        coordinator.workspacePillFrames = { frames }
        XCTAssertNotNil(coordinator.workspacePillFrames)
        XCTAssertEqual(coordinator.workspacePillFrames?().count, 2)
    }

    // MARK: - onWorkspaceHover callback

    func testOnWorkspaceHoverNilByDefault() {
        XCTAssertNil(coordinator.onWorkspaceHover)
    }

    func testOnWorkspaceHoverCanBeSet() {
        var firedIndex: Int?
        coordinator.onWorkspaceHover = { firedIndex = $0 }
        coordinator.onWorkspaceHover?(3)
        XCTAssertEqual(firedIndex, 3)
    }

    // MARK: - Hover timer fires after delay

    func testHoverTimerFiresAfterDelay() {
        let expectation = expectation(description: "onWorkspaceHover fires")
        var firedIndex: Int?

        let pillFrame = NSRect(x: 72, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = { [(index: 1, screenFrame: pillFrame)] }
        coordinator.onWorkspaceHover = { idx in
            firedIndex = idx
            expectation.fulfill()
        }

        // Simulate a drag event inside the pill rect
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 112, y: 19))

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(firedIndex, 1)
    }

    func testHoverTimerDoesNotFireBeforeDelay() {
        var fired = false
        let pillFrame = NSRect(x: 72, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = { [(index: 0, screenFrame: pillFrame)] }
        coordinator.onWorkspaceHover = { _ in fired = true }

        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 112, y: 19))

        // Check immediately — should not have fired yet
        XCTAssertFalse(fired)
    }

    // MARK: - Moving cursor cancels timer

    func testMovingCursorOutsidePillCancelsTimer() {
        var firedCount = 0
        let pillFrame = NSRect(x: 72, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = { [(index: 0, screenFrame: pillFrame)] }
        coordinator.onWorkspaceHover = { _ in firedCount += 1 }

        // Enter the pill
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 112, y: 19))
        // Immediately move outside
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 400, y: 400))

        // Wait longer than the hover delay
        let expectation = expectation(description: "timer window passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { expectation.fulfill() }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(firedCount, 0, "Timer should have been cancelled when cursor left pill")
    }

    func testMovingBetweenPillsCancelsOldTimer() {
        var firedIndexes: [Int] = []
        let pill0 = NSRect(x: 72, y: 7, width: 80, height: 24)
        let pill1 = NSRect(x: 158, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = {
            [(index: 0, screenFrame: pill0), (index: 1, screenFrame: pill1)]
        }
        coordinator.onWorkspaceHover = { firedIndexes.append($0) }

        // Hover pill0, then quickly move to pill1
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 112, y: 19))
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 198, y: 19))

        let expectation = expectation(description: "only pill1 fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { expectation.fulfill() }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(firedIndexes.count, 1, "Only the final pill should fire")
        XCTAssertEqual(firedIndexes.first, 1)
    }

    // MARK: - Same pill does not re-arm timer

    func testHoveringOverSamePillTwiceFiresOnce() {
        var firedCount = 0
        let pillFrame = NSRect(x: 72, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = { [(index: 0, screenFrame: pillFrame)] }
        coordinator.onWorkspaceHover = { _ in firedCount += 1 }

        // Move inside pill twice without leaving
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 100, y: 19))
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 120, y: 19))

        let expectation = expectation(description: "timer fires once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { expectation.fulfill() }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(firedCount, 1)
    }

    // MARK: - No pill hit

    func testNoPillHitDoesNotFireCallback() {
        var fired = false
        let pillFrame = NSRect(x: 72, y: 7, width: 80, height: 24)
        coordinator.workspacePillFrames = { [(index: 0, screenFrame: pillFrame)] }
        coordinator.onWorkspaceHover = { _ in fired = true }

        // Point far from pill
        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 500, y: 500))

        let expectation = expectation(description: "no fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { expectation.fulfill() }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(fired)
    }

    // MARK: - No frames closure

    func testNoFramesClosureIsNoop() {
        var fired = false
        coordinator.workspacePillFrames = nil
        coordinator.onWorkspaceHover = { _ in fired = true }

        coordinator.simulateHoverAt(screenPoint: NSPoint(x: 112, y: 19))

        let expectation = expectation(description: "no fire without frames")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { expectation.fulfill() }
        waitForExpectations(timeout: 1.0)

        XCTAssertFalse(fired)
    }
}
