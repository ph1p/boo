import XCTest

@testable import Boo

final class DragGhostWindowTests: XCTestCase {

    func testEasesTowardTarget() {
        let next = DragGhostWindow.eased(from: .zero, to: NSPoint(x: 100, y: -40))
        XCTAssertEqual(next.x, 100 * DragGhostWindow.follow, accuracy: 0.001)
        XCTAssertEqual(next.y, -40 * DragGhostWindow.follow, accuracy: 0.001)
    }

    func testSnapsWhenClose() {
        let target = NSPoint(x: 10, y: 10)
        XCTAssertEqual(DragGhostWindow.eased(from: NSPoint(x: 9.8, y: 10.3), to: target), target)
    }

    func testConvergesWithinAFewFrames() {
        var origin = NSPoint.zero
        let target = NSPoint(x: 400, y: 300)
        var frames = 0
        while origin != target, frames < 30 {
            origin = DragGhostWindow.eased(from: origin, to: target)
            frames += 1
        }
        XCTAssertEqual(origin, target)
        XCTAssertLessThanOrEqual(frames, 12)
    }
}
