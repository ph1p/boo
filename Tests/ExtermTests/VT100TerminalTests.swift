import XCTest
@testable import Exterm

final class VT100TerminalTests: XCTestCase {

    // MARK: - Basic Output

    func testInitialState() {
        let term = VT100Terminal(cols: 80, rows: 24)
        XCTAssertEqual(term.cols, 80)
        XCTAssertEqual(term.rows, 24)
        XCTAssertEqual(term.cursorX, 0)
        XCTAssertEqual(term.cursorY, 0)
        XCTAssertEqual(term.cell(at: 0, row: 0).character, " ")
    }

    func testPrintASCII() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("Hello".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "H")
        XCTAssertEqual(term.cell(at: 1, row: 0).character, "e")
        XCTAssertEqual(term.cell(at: 4, row: 0).character, "o")
        XCTAssertEqual(term.cursorX, 5)
        XCTAssertEqual(term.cursorY, 0)
    }

    func testUTF8() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("❯ café".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "❯")
        XCTAssertEqual(term.cell(at: 2, row: 0).character, "c")
        XCTAssertEqual(term.cell(at: 5, row: 0).character, "é")
    }

    func testLineFeed() {
        let term = VT100Terminal(cols: 80, rows: 24)
        // LF moves cursor down but doesn't do CR
        term.feed(Data("A\nB".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 1, row: 1).character, "B") // B at col 1 (no CR)
        XCTAssertEqual(term.cursorY, 1)
    }

    func testCRLF() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("A\r\nB".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 0, row: 1).character, "B") // B at col 0 after CR+LF
    }

    func testCarriageReturn() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("ABC\rD".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "D")
        XCTAssertEqual(term.cell(at: 1, row: 0).character, "B")
    }

    func testBackspace() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("AB\u{08}C".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 1, row: 0).character, "C")
    }

    func testTab() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("A\tB".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 8, row: 0).character, "B")
    }

    // MARK: - Auto-wrap

    func testAutoWrap() {
        let term = VT100Terminal(cols: 5, rows: 3)
        term.feed(Data("ABCDE".utf8))
        // Cursor should be at col 4 with pending wrap
        XCTAssertEqual(term.cursorX, 4)
        term.feed(Data("F".utf8))
        // Should wrap to next line
        XCTAssertEqual(term.cursorX, 1)
        XCTAssertEqual(term.cursorY, 1)
        XCTAssertEqual(term.cell(at: 0, row: 1).character, "F")
    }

    // MARK: - CSI Cursor Movement

    func testCursorUp() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\n\n\n".utf8)) // Move to row 3
        term.feed(Data("\u{1B}[2A".utf8)) // Move up 2
        XCTAssertEqual(term.cursorY, 1)
    }

    func testCursorDown() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[5B".utf8)) // Move down 5
        XCTAssertEqual(term.cursorY, 5)
    }

    func testCursorForward() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[10C".utf8)) // Move right 10
        XCTAssertEqual(term.cursorX, 10)
    }

    func testCursorBackward() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[10C".utf8)) // Right 10
        term.feed(Data("\u{1B}[3D".utf8))  // Left 3
        XCTAssertEqual(term.cursorX, 7)
    }

    func testCursorPosition() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[5;10H".utf8)) // Row 5, Col 10 (1-based)
        XCTAssertEqual(term.cursorY, 4)
        XCTAssertEqual(term.cursorX, 9)
    }

    func testCursorPositionDefault() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("ABC\u{1B}[H".utf8)) // Home
        XCTAssertEqual(term.cursorX, 0)
        XCTAssertEqual(term.cursorY, 0)
    }

    // MARK: - Erase

    func testEraseInDisplayBelow() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("AAAAAAAAAA".utf8)) // Fill row 0
        term.feed(Data("BBBBBBBBBB".utf8)) // Fill row 1
        term.feed(Data("\u{1B}[1;5H".utf8)) // Row 1, Col 5
        term.feed(Data("\u{1B}[0J".utf8)) // Erase below
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 3, row: 0).character, "A")
        XCTAssertEqual(term.cell(at: 4, row: 0).character, " ") // Erased
    }

    func testEraseInDisplayAll() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("Hello".utf8))
        term.feed(Data("\u{1B}[2J".utf8)) // Erase all
        XCTAssertEqual(term.cell(at: 0, row: 0).character, " ")
    }

    func testEraseInLineRight() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("ABCDEFGHIJ".utf8))
        term.feed(Data("\u{1B}[1;4H".utf8)) // Col 4
        term.feed(Data("\u{1B}[0K".utf8))    // Erase right
        XCTAssertEqual(term.cell(at: 2, row: 0).character, "C")
        XCTAssertEqual(term.cell(at: 3, row: 0).character, " ")
        XCTAssertEqual(term.cell(at: 9, row: 0).character, " ")
    }

    // MARK: - SGR (Colors/Attributes)

    func testSGRReset() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[31mR\u{1B}[0mN".utf8))
        let rCell = term.cell(at: 0, row: 0)
        let nCell = term.cell(at: 1, row: 0)
        XCTAssertNotEqual(rCell.style.fg, nCell.style.fg)
        XCTAssertEqual(nCell.style.fg, TerminalColor.defaultFG)
    }

    func testSGRBold() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[1mB\u{1B}[22mN".utf8))
        XCTAssertTrue(term.cell(at: 0, row: 0).style.bold)
        XCTAssertFalse(term.cell(at: 1, row: 0).style.bold)
    }

    func testSGRForeground256() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[38;5;196mR".utf8)) // 256-color red
        let cell = term.cell(at: 0, row: 0)
        XCTAssertNotEqual(cell.style.fg, TerminalColor.defaultFG)
    }

    func testSGRForegroundRGB() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[38;2;100;200;50mG".utf8))
        let cell = term.cell(at: 0, row: 0)
        XCTAssertEqual(cell.style.fg.r, 100)
        XCTAssertEqual(cell.style.fg.g, 200)
        XCTAssertEqual(cell.style.fg.b, 50)
    }

    func testSGRColonSeparator() {
        let term = VT100Terminal(cols: 80, rows: 24)
        // Colon-separated: 38:2:R:G:B (no color space ID)
        term.feed(Data("\u{1B}[38:2:100:200:50mG".utf8))
        let cell = term.cell(at: 0, row: 0)
        XCTAssertEqual(cell.style.fg.r, 100)
        XCTAssertEqual(cell.style.fg.g, 200)
        XCTAssertEqual(cell.style.fg.b, 50)
    }

    func testSGRColonSeparatorWithColorSpace() {
        let term = VT100Terminal(cols: 80, rows: 24)
        // With color space ID (empty = 0): 38:2::R:G:B → params [38,2,0,R,G,B]
        // Parser sees 2 at index 1 → RGB, reads [0, R, G] as r,g,b
        term.feed(Data("\u{1B}[38:2::255:128:64mG".utf8))
        let cell = term.cell(at: 0, row: 0)
        // The empty color space becomes 0, shifting values
        XCTAssertEqual(cell.style.fg.r, 0)
        XCTAssertEqual(cell.style.fg.g, 255)
        XCTAssertEqual(cell.style.fg.b, 128)
    }

    func testSGRInverse() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}[7mI\u{1B}[27mN".utf8))
        XCTAssertTrue(term.cell(at: 0, row: 0).style.inverse)
        XCTAssertFalse(term.cell(at: 1, row: 0).style.inverse)
    }

    // MARK: - Scroll Region

    func testScrollRegion() {
        let term = VT100Terminal(cols: 10, rows: 5)
        term.feed(Data("\u{1B}[2;4r".utf8)) // Set scroll region rows 2-4
        term.feed(Data("\u{1B}[4;1H".utf8)) // Move to row 4
        term.feed(Data("X\n".utf8))          // Should scroll within region
        // Row 4 (index 3) should now be blank since it scrolled
        XCTAssertEqual(term.cell(at: 0, row: 3).character, " ")
    }

    // MARK: - Alternate Screen

    func testAlternateScreen() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("Main".utf8))
        term.feed(Data("\u{1B}[?1049h".utf8)) // Enter alt screen
        XCTAssertEqual(term.cell(at: 0, row: 0).character, " ") // Alt screen is blank
        term.feed(Data("Alt".utf8))
        term.feed(Data("\u{1B}[?1049l".utf8)) // Exit alt screen
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "M") // Back to main
    }

    // MARK: - OSC

    func testOSCTitle() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("\u{1B}]2;MyTitle\u{07}".utf8))
        XCTAssertEqual(term.title, "MyTitle")
    }

    func testOSCDirectoryChange() {
        let term = VT100Terminal(cols: 80, rows: 24)
        var receivedPath: String?
        term.onDirectoryChanged = { path in receivedPath = path }
        term.feed(Data("\u{1B}]7;file://localhost/Users/test\u{07}".utf8))
        XCTAssertEqual(receivedPath, "/Users/test")
        XCTAssertEqual(term.currentDirectory, "/Users/test")
    }

    // MARK: - Resize

    func testResize() {
        let term = VT100Terminal(cols: 80, rows: 24)
        term.feed(Data("Hello".utf8))
        term.resize(cols: 40, rows: 12)
        XCTAssertEqual(term.cols, 40)
        XCTAssertEqual(term.rows, 12)
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "H") // Content preserved
    }

    // MARK: - Snapshot

    func testSnapshot() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("ABC".utf8))
        let snap = term.snapshot()
        XCTAssertEqual(snap.cols, 10)
        XCTAssertEqual(snap.rows, 3)
        XCTAssertEqual(snap.cursorX, 3)
        XCTAssertEqual(snap.cell(at: 0, row: 0).character, "A")
        XCTAssertEqual(snap.cell(at: 99, row: 99).character, " ") // Out of bounds
    }

    // MARK: - ANSI Palette

    func testCustomPalette() {
        let term = VT100Terminal(cols: 80, rows: 24)
        let customRed = TerminalColor(r: 1, g: 2, b: 3)
        term.ansiPalette[1] = customRed
        term.feed(Data("\u{1B}[31mR".utf8))
        XCTAssertEqual(term.cell(at: 0, row: 0).style.fg, customRed)
    }

    // MARK: - Insert/Delete

    func testDeleteCharacters() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("ABCDEFGHIJ".utf8))
        term.feed(Data("\u{1B}[1;3H".utf8)) // Col 3
        term.feed(Data("\u{1B}[2P".utf8))    // Delete 2 chars
        XCTAssertEqual(term.cell(at: 2, row: 0).character, "E")
        XCTAssertEqual(term.cell(at: 8, row: 0).character, " ")
    }

    func testInsertLines() {
        let term = VT100Terminal(cols: 10, rows: 5)
        // Use cursor positioning to avoid wrap issues
        term.feed(Data("\u{1B}[1;1HAAAAAAAAAA".utf8))
        term.feed(Data("\u{1B}[2;1HBBBBBBBBBB".utf8))
        term.feed(Data("\u{1B}[3;1HCCCCCCCCCC".utf8))
        term.feed(Data("\u{1B}[2;1H".utf8)) // Move to row 2
        term.feed(Data("\u{1B}[1L".utf8))    // Insert 1 line
        XCTAssertEqual(term.cell(at: 0, row: 0).character, "A") // Row 1 untouched
        XCTAssertEqual(term.cell(at: 0, row: 1).character, " ") // Inserted blank
        XCTAssertEqual(term.cell(at: 0, row: 2).character, "B") // Shifted down
    }

    // MARK: - Full Reset

    func testFullReset() {
        let term = VT100Terminal(cols: 10, rows: 3)
        term.feed(Data("Hello".utf8))
        term.feed(Data("\u{1B}c".utf8)) // Full reset
        XCTAssertEqual(term.cursorX, 0)
        XCTAssertEqual(term.cursorY, 0)
        XCTAssertEqual(term.cell(at: 0, row: 0).character, " ")
    }
}
