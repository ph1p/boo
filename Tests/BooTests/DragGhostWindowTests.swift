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

    @MainActor func testSourceFrameGhostKeepsGrabOffset() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let source = NSRect(x: 100, y: 100, width: 40, height: 20)
        let ghost = DragGhostWindow(content: content, sourceFrame: source, cursor: NSPoint(x: 110, y: 105))
        defer { ghost.orderOut(nil) }
        XCTAssertEqual(ghost.frame.origin, source.origin)
        // Cursor moves by (+50, -30): the ghost's target moves by the same amount.
        ghost.move(toCenter: NSPoint(x: 160, y: 75))
        var origin = ghost.frame.origin
        for _ in 0..<30 { origin = DragGhostWindow.eased(from: origin, to: NSPoint(x: 150, y: 70)) }
        XCTAssertEqual(origin, NSPoint(x: 150, y: 70))
    }
}
