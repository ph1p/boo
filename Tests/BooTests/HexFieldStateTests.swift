import XCTest

@testable import Boo

final class HexFieldStateTests: XCTestCase {

    // MARK: - Incomplete

    func testEmptyStringIsIncomplete() {
        XCTAssertEqual(hexFieldState(for: ""), .incomplete)
    }

    func testHashOnlyIsIncomplete() {
        XCTAssertEqual(hexFieldState(for: "#"), .incomplete)
    }

    func testPartialThreeCharsIsIncomplete() {
        XCTAssertEqual(hexFieldState(for: "#fff"), .incomplete)
    }

    func testPartialFiveCharsIsIncomplete() {
        XCTAssertEqual(hexFieldState(for: "#fffff"), .incomplete)
    }

    func testPartialFiveCharsNoHashIsIncomplete() {
        XCTAssertEqual(hexFieldState(for: "fffff"), .incomplete)
    }

    // MARK: - Valid

    func testWhiteIsValid() {
        XCTAssertEqual(hexFieldState(for: "#ffffff"), .valid(TerminalColor(r: 255, g: 255, b: 255)))
    }

    func testBlackIsValid() {
        XCTAssertEqual(hexFieldState(for: "#000000"), .valid(TerminalColor(r: 0, g: 0, b: 0)))
    }

    func testUppercaseIsValid() {
        XCTAssertEqual(hexFieldState(for: "#FFFFFF"), .valid(TerminalColor(r: 255, g: 255, b: 255)))
    }

    func testMixedCaseIsValid() {
        XCTAssertEqual(hexFieldState(for: "#fFfFfF"), .valid(TerminalColor(r: 255, g: 255, b: 255)))
    }

    func testArbitraryColorIsValid() {
        XCTAssertEqual(hexFieldState(for: "#1a2b3c"), .valid(TerminalColor(r: 0x1a, g: 0x2b, b: 0x3c)))
    }

    func testNoHashPrefixIsValid() {
        XCTAssertEqual(hexFieldState(for: "ff0000"), .valid(TerminalColor(r: 255, g: 0, b: 0)))
    }

    // MARK: - Invalid

    func testSevenCharsIsInvalid() {
        XCTAssertEqual(hexFieldState(for: "#fffffff"), .invalid)
    }

    func testSixNonHexCharsIsInvalid() {
        XCTAssertEqual(hexFieldState(for: "#zzzzzz"), .invalid)
    }

    func testPartiallyInvalidSixCharsIsInvalid() {
        XCTAssertEqual(hexFieldState(for: "#gg0000"), .invalid)
    }

    // MARK: - Luminance / contrast

    func testWhiteLuminanceIsHigh() {
        let c = TerminalColor(r: 255, g: 255, b: 255)
        XCTAssertGreaterThan(c.luminance, 0.5)
    }

    func testBlackLuminanceIsLow() {
        let c = TerminalColor(r: 0, g: 0, b: 0)
        XCTAssertLessThanOrEqual(c.luminance, 0.5)
    }

    func testMidGreyLuminanceIsAboutHalf() {
        let c = TerminalColor(r: 128, g: 128, b: 128)
        XCTAssertGreaterThan(c.luminance, 0.4)
        XCTAssertLessThan(c.luminance, 0.6)
    }

    func testDarkRedLuminanceIsLow() {
        let c = TerminalColor(r: 139, g: 0, b: 0)
        XCTAssertLessThan(c.luminance, 0.5)
    }

    func testLightYellowLuminanceIsHigh() {
        let c = TerminalColor(r: 255, g: 255, b: 0)
        XCTAssertGreaterThan(c.luminance, 0.5)
    }
}
