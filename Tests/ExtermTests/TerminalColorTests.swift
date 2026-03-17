import XCTest
@testable import Exterm

final class TerminalColorTests: XCTestCase {

    func testDefaultColors() {
        XCTAssertEqual(TerminalColor.defaultFG, TerminalColor(r: 228, g: 228, b: 232))
        XCTAssertEqual(TerminalColor.defaultBG, TerminalColor(r: 21, g: 21, b: 23))
    }

    func testCGColorConversion() {
        let c = TerminalColor(r: 255, g: 128, b: 0)
        let cg = c.cgColor
        XCTAssertNotNil(cg)
        // CGColor components are in [0,1]
        let components = cg.components!
        XCTAssertEqual(components[0], 1.0, accuracy: 0.01)
        XCTAssertEqual(components[1], 128.0/255.0, accuracy: 0.01)
        XCTAssertEqual(components[2], 0.0, accuracy: 0.01)
    }

    func testNSColorConversion() {
        let c = TerminalColor(r: 100, g: 200, b: 50)
        let ns = c.nsColor
        XCTAssertEqual(ns.redComponent, 100.0/255.0, accuracy: 0.01)
        XCTAssertEqual(ns.greenComponent, 200.0/255.0, accuracy: 0.01)
        XCTAssertEqual(ns.blueComponent, 50.0/255.0, accuracy: 0.01)
    }

    func testEquality() {
        let a = TerminalColor(r: 10, g: 20, b: 30)
        let b = TerminalColor(r: 10, g: 20, b: 30)
        let c = TerminalColor(r: 10, g: 20, b: 31)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testAnsiColorCount() {
        XCTAssertEqual(TerminalColor.ansiColors.count, 16)
    }
}
