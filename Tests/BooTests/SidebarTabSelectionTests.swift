import XCTest

@testable import Boo

/// A tab hidden by its when-clause (Agents while ssh runs) comes back once visible.
@MainActor
final class SidebarTabSelectionTests: XCTestCase {
    private func select(
        active: String?, displaced: String? = nil, remembered: String? = nil, available: [String]
    ) -> (show: String, displaced: String?)? {
        MainWindowController.sidebarTabSelection(
            active: active, displaced: displaced, remembered: remembered, available: available)
    }

    func testKeepsTheActiveTab() {
        let choice = select(active: "agents", available: ["file-tree", "agents"])
        XCTAssertEqual(choice?.show, "agents")
        XCTAssertNil(choice?.displaced)
    }

    func testHiddenTabIsRememberedAndRestored() {
        let during = select(active: "agents", remembered: "agents", available: ["file-tree-remote", "git"])
        XCTAssertEqual(during?.show, "file-tree-remote")
        XCTAssertEqual(during?.displaced, "agents")

        let after = select(
            active: "file-tree-remote", displaced: "agents", remembered: "file-tree-remote",
            available: ["file-tree", "agents"])
        XCTAssertEqual(after?.show, "agents", "back to the tab the user had open, not the first one")
        XCTAssertNil(after?.displaced)
    }

    func testFallbackPrefersTheRememberedTab() {
        XCTAssertEqual(select(active: nil, remembered: "git", available: ["file-tree", "git"])?.show, "git")
        XCTAssertEqual(select(active: nil, remembered: "gone", available: ["file-tree", "git"])?.show, "file-tree")
        XCTAssertNil(select(active: "agents", available: []))
    }
}
