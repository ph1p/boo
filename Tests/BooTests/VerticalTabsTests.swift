import XCTest

@testable import Boo

@MainActor
final class VerticalTabsTests: XCTestCase {
    private var savedMode: Any?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.object(forKey: "tabOverflowMode")
        UserDefaults.standard.set(TabOverflowMode.vertical.rawValue, forKey: "tabOverflowMode")
    }

    override func tearDown() {
        if let savedMode {
            UserDefaults.standard.set(savedMode, forKey: "tabOverflowMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "tabOverflowMode")
        }
        super.tearDown()
    }

    private func paneView(_ count: Int, width: CGFloat = 900) -> (Pane, PaneView) {
        let pane = Pane(id: UUID())
        for i in 0..<count { _ = pane.addTab(workingDirectory: "/tmp/\(i)") }
        pane.setActiveTab(0)
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        return (pane, pv)
    }

    func testColumnReplacesTopBar() {
        let (_, pv) = paneView(2)
        XCTAssertTrue(pv.isVerticalTabs)
        XCTAssertEqual(pv.tabBarHeight, 0)
        XCTAssertEqual(pv.verticalTabColumnWidth, PaneView.verticalTabColumnMaxWidth)
        XCTAssertTrue(pv.isInTabBar(NSPoint(x: 10, y: 300)))
        XCTAssertFalse(pv.isInTabBar(NSPoint(x: 400, y: 10)))
    }

    func testNarrowPaneCapsColumn() {
        let (_, pv) = paneView(1, width: 200)
        XCTAssertEqual(pv.verticalTabColumnWidth, 80)
    }

    func testSlotsStackAndHitByY() throws {
        let (_, pv) = paneView(3)
        let row = PaneView.verticalTabRowHeight
        XCTAssertEqual(pv.verticalSlotHeights(), [row, row, row])
        let s1 = try XCTUnwrap(pv.tabSlotRect(at: 1))
        let s0 = try XCTUnwrap(pv.tabSlotRect(at: 0))
        XCTAssertEqual(s1.minY, s0.maxY)
        XCTAssertEqual(pv.tabIndex(at: NSPoint(x: 20, y: s1.midY)), 1)
        XCTAssertNil(pv.tabIndex(at: NSPoint(x: 400, y: s1.midY)), "terminal area is not a tab")
        XCTAssertNil(pv.tabIndex(at: NSPoint(x: 20, y: pv.verticalPlusSlot.midY)), "plus is not a tab")
    }

    func testGroupHeaderAndCollapse() throws {
        let (p, pv) = paneView(4)
        let gid = try XCTUnwrap(p.groupTab(at: 2, with: 1))  // a [b c] d
        let row = PaneView.verticalTabRowHeight
        let header = PaneView.verticalGroupHeaderHeight
        XCTAssertEqual(pv.verticalSlotHeights(), [row, header + row, row, row])

        let slot = try XCTUnwrap(pv.tabSlotRect(at: 1))
        XCTAssertEqual(pv.groupChipHit(at: NSPoint(x: 20, y: slot.minY + 4), tabIndex: 1), gid)
        XCTAssertNil(pv.groupChipHit(at: NSPoint(x: 20, y: slot.maxY - 4), tabIndex: 1))
        let pill = try XCTUnwrap(pv.visibleTabPillRect(at: 1))
        XCTAssertGreaterThanOrEqual(pill.minY, slot.minY + header)

        pv.toggleGroupCollapsed(gid)
        XCTAssertEqual(pv.verticalSlotHeights(), [row, header, 0, row])
        XCTAssertNil(pv.visibleTabPillRect(at: 2))
    }

    func testInsertionIndexByRowMiddle() throws {
        let (_, pv) = paneView(3)
        let s1 = try XCTUnwrap(pv.tabSlotRect(at: 1))
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 20, y: s1.minY + 2)), 1)
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 20, y: s1.maxY - 2)), 2)
        XCTAssertEqual(pv.tabInsertionIndex(at: NSPoint(x: 20, y: 390)), 3)
        XCTAssertEqual(pv.tabInsertionPosition(at: 1).y, s1.minY)
    }

    func testScrollOnlyWhenRowsOverflow() {
        let (_, few) = paneView(2)
        XCTAssertEqual(few.verticalScrollMaxOffset(), 0)
        let (_, many) = paneView(20)
        XCTAssertGreaterThan(many.verticalScrollMaxOffset(), 0)
    }
}
