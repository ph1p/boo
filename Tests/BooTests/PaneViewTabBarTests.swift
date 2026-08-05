import XCTest

@testable import Boo

@MainActor final class PaneViewTabBarTests: XCTestCase {

    private func makePaneView(tabTitles: [String], width: CGFloat = 600) -> PaneView {
        let pane = Pane()
        for title in tabTitles {
            pane.addTab(workingDirectory: "/tmp", title: title)
        }
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        return pv
    }

    // MARK: - measuredTabWidth

    func testMeasuredTabWidth_shortTitle() {
        let pane = Pane()
        pane.addTab(workingDirectory: "/tmp", title: "~")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let w = pv.measuredTabWidth(for: pane.tabs[0])
        // Short title stays near tabMinWidth (60) — no dead space padding
        XCTAssertGreaterThanOrEqual(w, 60)
        XCTAssertLessThanOrEqual(w, 70)
    }

    func testMeasuredTabWidth_longTitle() {
        // Use a remote session tab so tabDisplayTitle returns the remote CWD directly
        let pane = Pane()
        pane.addTab(
            workingDirectory: "/tmp",
            title: "user@host:/very/long/path/to/some/deeply/nested/directory/structure")
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
        pane.addTab(workingDirectory: "/tmp", title: "Documents")
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let w = pv.measuredTabWidth(for: pane.tabs[0])
        XCTAssertGreaterThanOrEqual(w, 60)
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
        XCTAssertEqual(layouts[0].y, layouts[1].y)
        // First starts at the side inset, first row below the top inset
        XCTAssertEqual(layouts[0].x, PaneView.tabBarSideInset)
        XCTAssertEqual(layouts[0].y, PaneView.tabBarSideInset)
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

    func testWrapLayout_naturalWidthsNoStretch() {
        // Pills keep their measured width — no row is stretched to fill the bar.
        let titles = Array(repeating: "/some/medium/path", count: 4)
        let pv = makePaneView(tabTitles: titles, width: 500)
        let layouts = pv.wrapLayout()
        let widths = pv.allTabWidths()
        XCTAssertEqual(layouts.count, widths.count)
        for (lay, w) in zip(layouts, widths) {
            XCTAssertEqual(lay.width, w, accuracy: 0.01, "wrap must keep natural pill widths")
        }
        // Every row stays inside the side insets
        for lay in layouts {
            XCTAssertGreaterThanOrEqual(lay.x, PaneView.tabBarSideInset)
            XCTAssertLessThanOrEqual(lay.x + lay.width, 500 - PaneView.tabBarSideInset + 0.01)
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
        let row1Y = PaneView.tabBarSideInset + pv.singleRowTabHeight
        let row1Tabs = layouts.enumerated().filter { $0.element.y == row1Y }
        guard let firstRow1 = row1Tabs.first else {
            XCTFail("No second row")
            return
        }
        // Inserting at x=0 on row 1 should give the first tab index of row 1
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 0, y: row1Y)), firstRow1.offset)
    }

    // MARK: - tabInsertionPosition

    func testTabInsertionPosition_scroll_firstTab() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let pt = pv.tabInsertionPosition(at: 0)
        XCTAssertEqual(pt.x, PaneView.tabBarSideInset)
        XCTAssertEqual(pt.y, 0)
    }

    func testTabInsertionPosition_scroll_middleTab() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let widths = pv.allTabWidths()
        let pt = pv.tabInsertionPosition(at: 1)
        XCTAssertEqual(pt.x, PaneView.tabBarSideInset + widths[0], accuracy: 0.01)
        XCTAssertEqual(pt.y, 0)
    }

    func testTabInsertionPosition_scroll_afterLast() {
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 600)
        let widths = pv.allTabWidths()
        let totalW = widths.reduce(0, +)
        let pt = pv.tabInsertionPosition(at: 3)
        XCTAssertEqual(pt.x, PaneView.tabBarSideInset + totalW, accuracy: 0.01)
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

    // MARK: - Plus Button Visibility in Wrap Mode

    func testWrapLayout_plusButtonPosition_fitsOnLastRow() {
        // 2 tabs at ~100px in 250px = 200px, plus 32px = 232px fits
        let pv = makePaneView(tabTitles: ["~", "~"], width: 250)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        let layouts = pv.wrapLayout()
        let lastLay = layouts.last!
        let plusX = lastLay.x + lastLay.width
        let plusY = lastLay.y

        // Plus button should fit on same row (first row, below the top inset)
        XCTAssertEqual(plusY, PaneView.tabBarSideInset, "Plus should be on first row")
        // plusX + plusButtonWidth should fit within bounds (with tolerance for floating point)
        XCTAssertLessThanOrEqual(plusX + pv.plusButtonWidth, 250 + 1, "Plus button must fit within bounds")
    }

    func testWrapLayout_plusButtonPosition_overflowsToNewRow() {
        // 2 tabs at ~62px = 124px in 150px leaves 20px of row — the 32px plus
        // can't fit and must drop to a new row.
        let pv = makePaneView(tabTitles: ["~", "~"], width: 150)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        let layouts = pv.wrapLayout()

        // Both tabs on row 0 at natural width; 3 + 200 + 32 > 220 - 3, so the
        // plus doesn't fit and drops to a row of its own.
        XCTAssertTrue(layouts.allSatisfy { $0.y == PaneView.tabBarSideInset }, "Both tabs stay on row 0")
        XCTAssertFalse(pv.plusFitsOnLastRow(layouts), "Plus must not fit after the tabs")
        let rows = Int(pv.tabBarHeight / pv.singleRowTabHeight)
        XCTAssertEqual(rows, 2, "Should have 2 rows: 1 for tabs, 1 for plus button")
    }

    func testWrapLayout_plusButtonAlwaysAccessible_edgeCaseWidths() {
        // Test various edge case widths where plus button might disappear
        let pv = makePaneView(tabTitles: ["~", "~", "~"], width: 300)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        // Test resize from wide to narrow
        for width in stride(from: 350, through: 150, by: -10) {
            pv.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 300)

            let layouts = pv.wrapLayout()
            guard let lastLay = layouts.last else { continue }

            let plusX = lastLay.x + lastLay.width
            let plusY = lastLay.y
            let barHeight = pv.tabBarHeight

            // Plus button must fit either:
            // 1. On same row as last tab (plusX + 32 <= width), or
            // 2. On new row (plusY + singleRowTabHeight <= barHeight)
            let fitsOnLastRow = plusX + pv.plusButtonWidth <= CGFloat(width)
            let fitsOnNewRow = plusY + pv.singleRowTabHeight <= barHeight

            XCTAssertTrue(
                fitsOnLastRow || fitsOnNewRow,
                "Plus button must be visible at width \(width): plusX=\(plusX), plusY=\(plusY), barHeight=\(barHeight)")
        }
    }

    func testWrapLayout_plusButtonDrawPosition_matchesBarHeight() {
        // The actual plus button draw position (as computed in drawTabsWrapped)
        // must always be within tabBarHeight bounds
        let pv = makePaneView(tabTitles: ["~", "~", "~", "~"], width: 300)
        UserDefaults.standard.set(TabOverflowMode.wrap.rawValue, forKey: "tabOverflowMode")
        defer { UserDefaults.standard.removeObject(forKey: "tabOverflowMode") }

        // Test at various widths including the previously failing width 250
        for width in stride(from: 400, through: 100, by: -5) {
            pv.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 300)

            let layouts = pv.wrapLayout()
            guard !layouts.isEmpty else { continue }

            let lastLay = layouts.last!
            let plusY = lastLay.y
            let barHeight = pv.tabBarHeight

            // Mirror the draw logic: plus follows the last tab when it fits,
            // else drops onto a row of its own.
            let plusOnLastRow = pv.plusFitsOnLastRow(layouts)

            let actualPlusY = plusOnLastRow ? plusY : plusY + pv.singleRowTabHeight

            // Plus button bottom edge must not exceed tab bar height
            let plusBottomY = actualPlusY + pv.singleRowTabHeight
            XCTAssertLessThanOrEqual(
                plusBottomY, barHeight,
                "Plus button overflows bar at width \(width): plusY=\(actualPlusY), bottom=\(plusBottomY), barHeight=\(barHeight)"
            )
        }
    }

}
