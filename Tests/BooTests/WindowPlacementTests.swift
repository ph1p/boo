import Cocoa
import XCTest

@testable import Boo

final class WindowPlacementTests: XCTestCase {
    private let laptop = PlacementScreen(
        id: "LAPTOP", frame: NSRect(x: 0, y: 0, width: 1800, height: 1130),
        visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1100))
    private let external = PlacementScreen(
        id: "EXTERNAL", frame: NSRect(x: 1800, y: 0, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 1800, y: 0, width: 2560, height: 1415))

    func testCaptureUsesScreenHoldingMostOfTheFrame() {
        let placement = WindowPlacementResolver.capture(
            NSRect(x: 1700, y: 100, width: 1000, height: 700), in: [laptop, external])
        XCTAssertEqual(placement.screenID, "EXTERNAL")
        XCTAssertEqual(placement.screenFrame, [1800, 0, 2560, 1440])
    }

    func testSameArrangementRestoresFrameUnchanged() {
        let frame = NSRect(x: 2000, y: 200, width: 1200, height: 800)
        let placement = WindowPlacement(frame: frame, screen: external)
        let resolved = WindowPlacementResolver.resolve(placement, in: [laptop, external])
        XCTAssertEqual(resolved?.frame, frame)
        XCTAssertEqual(resolved?.onSavedScreen, true)
    }

    func testRearrangedDisplayKeepsOffsetWithinIt() {
        let placement = WindowPlacement(frame: NSRect(x: 2000, y: 200, width: 1200, height: 800), screen: external)
        // External moved from the right of the laptop to its left.
        let moved = PlacementScreen(
            id: "EXTERNAL", frame: NSRect(x: -2560, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: -2560, y: 0, width: 2560, height: 1415))
        let resolved = WindowPlacementResolver.resolve(placement, in: [laptop, moved])
        XCTAssertEqual(resolved?.frame, NSRect(x: -2360, y: 200, width: 1200, height: 800))
        XCTAssertEqual(resolved?.onSavedScreen, true)
    }

    func testMissingDisplayFallsBackFullyOnScreen() {
        let placement = WindowPlacement(frame: NSRect(x: 2000, y: 200, width: 1200, height: 800), screen: external)
        let resolved = WindowPlacementResolver.resolve(placement, in: [laptop])
        XCTAssertEqual(resolved?.onSavedScreen, false)
        let frame = try? XCTUnwrap(resolved?.frame)
        XCTAssertEqual(frame?.size, NSSize(width: 1200, height: 800))
        XCTAssertTrue(laptop.visibleFrame.contains(frame ?? .zero))
    }

    func testHalfOffScreenFrameIsPulledInside() {
        let placement = WindowPlacement(frame: [1500, -300, 1000, 700])
        let resolved = WindowPlacementResolver.resolve(placement, in: [laptop])
        XCTAssertEqual(resolved?.frame, NSRect(x: 800, y: 0, width: 1000, height: 700))
        XCTAssertEqual(resolved?.onSavedScreen, true)
    }

    func testFrameLargerThanScreenShrinksToFit() {
        let placement = WindowPlacement(frame: NSRect(x: 1900, y: 0, width: 2400, height: 1400), screen: external)
        let resolved = WindowPlacementResolver.resolve(placement, in: [laptop])
        XCTAssertEqual(resolved?.frame, laptop.visibleFrame)
    }

    func testInvalidFrameDoesNotResolve() {
        XCTAssertNil(WindowPlacementResolver.resolve(WindowPlacement(frame: [0, 0, 0, 10]), in: [laptop]))
        XCTAssertNil(WindowPlacementResolver.resolve(WindowPlacement(frame: [0, 0, 10, 10]), in: []))
    }

    func testSessionWindowRoundTripsPlacement() throws {
        var window = SessionWindow(activeWorkspaceIndex: 0, workspaces: [])
        window.frame = [10, 20, 800, 600]
        window.screenID = "LAPTOP"
        window.screenFrame = [0, 0, 1800, 1130]
        window.homePlacement = WindowPlacement(frame: NSRect(x: 2000, y: 0, width: 900, height: 700), screen: external)
        let decoded = try JSONDecoder().decode(SessionWindow.self, from: JSONEncoder().encode(window))
        XCTAssertEqual(
            decoded.placement,
            WindowPlacement(frame: [10, 20, 800, 600], screenID: "LAPTOP", screenFrame: [0, 0, 1800, 1130]))
        XCTAssertEqual(decoded.homePlacement, window.homePlacement)
    }
}
