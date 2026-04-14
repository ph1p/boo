import XCTest

@testable import Boo

/// Tests for PluginTabContext — the typed tab registration and deduplication context.
final class PluginTabContextTests: XCTestCase {

    func testDefaultKeyIsEmpty() {
        let ctx = PluginTabContext(title: "Diff", icon: "doc.badge.plus")
        XCTAssertEqual(ctx.key, "")
    }

    func testCustomKeyIsStored() {
        let ctx = PluginTabContext(title: "Diff", icon: "doc.badge.plus", key: "/path/to/file.swift")
        XCTAssertEqual(ctx.key, "/path/to/file.swift")
    }

    func testTitleAndIconStored() {
        let ctx = PluginTabContext(title: "My Tab", icon: "star.fill", key: "k1")
        XCTAssertEqual(ctx.title, "My Tab")
        XCTAssertEqual(ctx.icon, "star.fill")
    }

    /// Verify that the deduplication key format used in handleOpenMultiContentTab is consistent.
    func testDedupeKeyFormat() {
        let typeID = "git-diff"
        let ctx = PluginTabContext(title: "Diff", icon: "doc", key: "/some/path")
        let dedupeKey = "\(typeID):\(ctx.key)"
        XCTAssertEqual(dedupeKey, "git-diff:/some/path")
    }

    func testDedupeKeyWithEmptyContextKey() {
        let typeID = "my-panel"
        let ctx = PluginTabContext(title: "Panel", icon: "star")
        let dedupeKey = "\(typeID):\(ctx.key)"
        XCTAssertEqual(dedupeKey, "my-panel:")
    }
}
