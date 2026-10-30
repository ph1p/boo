import XCTest

@testable import Boo

@MainActor
final class CopyModeTests: XCTestCase {
    private func mode(_ lines: [String], at cursor: CopyMode.Point = .init(row: 0, column: 0)) -> CopyMode {
        CopyMode(
            cursor: cursor, rows: lines.count, columns: 20, pageRows: 4,
            cells: { CopyMode.cells(of: lines.indices.contains($0) ? lines[$0] : "") })
    }

    func testBasicMotionsClampToScreen() {
        var m = mode(["abc", "def"])
        m.move(.left)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 0))
        m.move(.down, count: 5)
        XCTAssertEqual(m.cursor.row, 1)
        m.move(.right, count: 50)
        XCTAssertEqual(m.cursor.column, 19)
        m.move(.lineEnd)
        XCTAssertEqual(m.cursor.column, 2)
    }

    func testWordMotionsCrossPunctuationAndLines() {
        var m = mode(["foo.bar  baz", "  next"])
        m.move(.wordForward)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 3))
        m.move(.wordForward)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 4))
        m.move(.wordForward)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 9))
        m.move(.wordForward)
        XCTAssertEqual(m.cursor, .init(row: 1, column: 2))
        m.move(.wordBackward)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 9))
        m.move(.wordEnd)
        XCTAssertEqual(m.cursor, .init(row: 0, column: 11))
    }

    func testFirstNonBlank() {
        var m = mode(["    indented"], at: .init(row: 0, column: 10))
        m.move(.firstNonBlank)
        XCTAssertEqual(m.cursor.column, 4)
    }

    func testCharacterSelectionIsOrderedAndInclusive() {
        var m = mode(["hello world"], at: .init(row: 0, column: 6))
        m.toggleSelection(.character)
        m.move(.left, count: 3)
        let range = try? XCTUnwrap(m.range)
        XCTAssertEqual(range?.start, .init(row: 0, column: 3))
        XCTAssertEqual(range?.end, .init(row: 0, column: 6))
    }

    func testLineSelectionSpansFullRows() {
        var m = mode(["a", "b", "c"], at: .init(row: 2, column: 0))
        m.toggleSelection(.line)
        m.move(.up)
        XCTAssertEqual(m.range?.start, .init(row: 1, column: 0))
        XCTAssertEqual(m.range?.end, .init(row: 2, column: 19))
        m.toggleSelection(.line)
        XCTAssertNil(m.range)
    }

    func testWideCharactersTakeTwoCells() {
        XCTAssertEqual(CopyMode.cells(of: "a漢b"), ["a", "漢", "", "b"])
        var m = mode(["漢字 x"])
        m.move(.wordForward)
        XCTAssertEqual(m.cursor.column, 5)
    }
}
