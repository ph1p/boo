import XCTest

@testable import Boo

final class PaneViewTabBarTests: XCTestCase {

    private func makePaneView(tabTitles: [String], width: CGFloat = 600) -> PaneView {
        let pane = Pane()
        for title in tabTitles {
            pane.addTab(id: UUID(), title: title, workingDirectory: "/tmp")
        }
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        return pv
    }

    // MARK: - measuredTabWidth

    func testMeasuredTabWidth_shortTitle() {
        let pane = Pane()
        pane.addTab(id: UUID(), title: "~", workingDirectory: "/tmp")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let w = pv.measuredTabWidth(for: pane.tabs[0])
        // Short title should clamp to tabMinWidth (100)
        XCTAssertEqual(w, 100, accuracy: 5)
    }

    func testMeasuredTabWidth_longTitle() {
        // Use a remote session tab so tabDisplayTitle returns the remote CWD directly
        let pane = Pane()
        pane.addTab(
            id: UUID(), title: "user@host:/very/long/path/to/some/deeply/nested/directory/structure",
            workingDirectory: "/tmp")
        // Set a remote session so tabDisplayTitle extracts the path after ":"
        pane.updateRemoteSession(at: 0, .ssh(host: "user@host"))
        pane.updateRemoteWorkingDirectory(at: 0, "/very/long/path/to/some/deeply/nested/directory/structure")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let w = pv.measuredTabWidth(for: pane.tabs[0])
        // Long title should clamp to tabMaxWidth (180)
        XCTAssertEqual(w, 180)
    }

    func testMeasuredTabWidth_mediumTitle() {
        let pane = Pane()
        pane.addTab(id: UUID(), title: "Documents", workingDirectory: "/tmp")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let w = pv.measuredTabWidth(for: pane.tabs[0])
        XCTAssertGreaterThanOrEqual(w, 100)
        XCTAssertLessThanOrEqual(w, 180)
    }

    // MARK: - allTabWidths

    func testAllTabWidths_count() {
        let pv = makePaneView(tabTitles: ["a", "b", "c"])
        XCTAssertEqual(pv.allTabWidths().count, 3)
    }

    // MARK: - scrollMaxOffset

    func testScrollMaxOffset_noOverflow() {
        let pv = makePaneView(tabTitles: ["~", "~"], width: 600)
        // 2 tabs at ~100 + 32 plus button = ~232, well under 600
        XCTAssertEqual(pv.scrollMaxOffset(), 0)
    }

    func testScrollMaxOffset_overflow() {
        // Many tabs at min width 100 each + 32 plus = 832, in 400px → overflow
        let titles = Array(repeating: "~", count: 8)
        let pv = makePaneView(tabTitles: titles, width: 400)
        XCTAssertGreaterThan(pv.scrollMaxOffset(), 0)
    }

    // MARK: - wrapLayout

    func testWrapLayout_singleRow() {
        let pv = makePaneView(tabTitles: ["~", "~"], width: 600)
        let layouts = pv.wrapLayout()
        XCTAssertEqual(layouts.count, 2)
        // Both on row 0
        XCTAssertEqual(layouts[0].y, 0)
        XCTAssertEqual(layouts[1].y, 0)
        // First starts at 0
        XCTAssertEqual(layouts[0].x, 0)
    }

    func testWrapLayout_multipleRows() {
        // 6 tabs at min 100px each = 600, in 250px → multiple rows
        let titles = Array(repeating: "~", count: 6)
        let pv = makePaneView(tabTitles: titles, width: 250)
        let layouts = pv.wrapLayout()
        XCTAssertEqual(layouts.count, 6)
        // Should have tabs on multiple rows
        let uniqueRows = Set(layouts.map { $0.y })
        XCTAssertGreaterThan(uniqueRows.count, 1)
    }

    func testWrapLayout_stretchFillsWidth() {
        // 4 tabs in 500px — first row should fill exactly 500 (minus plus button on last row)
        let titles = Array(repeating: "/some/medium/path", count: 4)
        let pv = makePaneView(tabTitles: titles, width: 500)
        let layouts = pv.wrapLayout()
        guard !layouts.isEmpty else {
            XCTFail("No layouts")
            return
        }

        // Group by row
        var rows: [CGFloat: [PaneView.TabLayout]] = [:]
        for lay in layouts {
            rows[lay.y, default: []].append(lay)
        }

        // For non-last rows, sum of widths should equal bounds width
        let sortedRowYs = rows.keys.sorted()
        for rowY in sortedRowYs.dropLast() {
            let rowLayouts = rows[rowY]!
            let rowSum = rowLayouts.reduce(0) { $0 + $1.width }
            XCTAssertEqual(rowSum, 500, accuracy: 1)
        }
    }

    // MARK: - tabInsertionIndex

    func testTabInsertionIndex_scroll() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        // Point at x=0 should insert at 0
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 0, y: 0)), 0)
        // Point past all tabs should insert at end
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 500, y: 0)), 3)
    }

    func testTabInsertionIndex_wrap() {
        let titles = Array(repeating: "~", count: 6)
        let pv = makePaneView(tabTitles: titles, width: 250)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        // Point at x=0, row 0 should insert at 0
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 0, y: 0)), 0)
        // Point past all on last row should insert at end
        let barH = pv.tabBarHeight
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 500, y: barH - 1)), 6)
    }

    func testTabInsertionIndex_wrap_secondRow() {
        let titles = Array(repeating: "~", count: 6)
        let pv = makePaneView(tabTitles: titles, width: 250)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        let layouts = pv.wrapLayout()
        // Find a tab on row 1
        let row1Tabs = layouts.enumerated().filter { $0.element.y == pv.singleRowTabHeight }
        guard let firstRow1 = row1Tabs.first else {
            XCTFail("No second row")
            return
        }
        // Inserting at x=0 on row 1 should give the first tab index of row 1
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 0, y: pv.singleRowTabHeight)), firstRow1.offset)
    }

    // MARK: - tabInsertionPosition

    func testTabInsertionPosition_scroll_firstTab() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let pt = pv.tabInsertionPosition(at: 0)
        XCTAssertEqual(pt.x, 0)
        XCTAssertEqual(pt.y, 0)
    }

    func testTabInsertionPosition_scroll_middleTab() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let widths = pv.allTabWidths()
        let pt = pv.tabInsertionPosition(at: 1)
        XCTAssertEqual(pt.x, widths[0], accuracy: 0.01)
        XCTAssertEqual(pt.y, 0)
    }

    func testTabInsertionPosition_scroll_afterLast() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let widths = pv.allTabWidths()
        let totalW = widths.reduce(0, +)
        let pt = pv.tabInsertionPosition(at: 3)
        XCTAssertEqual(pt.x, totalW, accuracy: 0.01)
        XCTAssertEqual(pt.y, 0)
    }

    func testTabInsertionPosition_wrap_matchesWrapLayout() {
        let titles = Array(repeating: "~", count: 6)
        let pv = makePaneView(tabTitles: titles, width: 250)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        let layouts = pv.wrapLayout()
        for i in 0..<layouts.count {
            let pt = pv.tabInsertionPosition(at: i)
            XCTAssertEqual(pt.x, layouts[i].x, accuracy: 0.01, "x mismatch at index \(i)")
            XCTAssertEqual(pt.y, layouts[i].y, accuracy: 0.01, "y mismatch at index \(i)")
        }
    }

}
