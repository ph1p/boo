import XCTest

@testable import Boo

@MainActor
final class SettingsTabSearchTests: XCTestCase {
    typealias Tab = SettingsView.Tab

    func testEmptyQueryKeepsEveryTab() {
        XCTAssertEqual(Tab.matching("  ", in: Tab.fixed), Tab.fixed)
    }

    func testMatchesLabelsAndKeywords() {
        XCTAssertEqual(Tab.matching("shortcuts", in: Tab.fixed), [.shortcuts])
        XCTAssertTrue(Tab.matching("font", in: Tab.fixed).contains(.appearance))
        XCTAssertTrue(Tab.matching("ITERM2", in: Tab.fixed).contains(.theme))
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(Tab.matching("minimap word", in: Tab.fixed), [.editor])
        XCTAssertTrue(Tab.matching("minimap regex", in: Tab.fixed).isEmpty)
    }

    func testFixedTabsAreOrderedByGroup() {
        let groups = Tab.fixed.map(\.group)
        let order = Tab.Group.allCases
        XCTAssertEqual(groups, groups.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        XCTAssertEqual(Set(groups), Set(order))
    }
}
