import XCTest

@testable import Boo

/// Tests for `SidebarTabOrdering` — the pure-logic helpers that sort and merge
/// sidebar tab order across local / remote context switches.
final class SidebarTabOrderingTests: XCTestCase {

    // MARK: - Helpers

    private func tab(_ id: String) -> SidebarTab {
        SidebarTab(
            id: SidebarTabID(id),
            icon: "star",
            label: id,
            sections: [])
    }

    private func ids(_ tabs: [SidebarTab]) -> [String] {
        tabs.map(\.id.id)
    }

    // MARK: - applied(tabs:savedOrder:)

    func testApplied_respectsSavedOrder() {
        let tabs = [tab("a"), tab("b"), tab("c")]
        let result = SidebarTabOrdering.applied(tabs: tabs, savedOrder: ["c", "a", "b"])
        XCTAssertEqual(ids(result), ["c", "a", "b"])
    }

    func testApplied_emptySavedOrderPreservesRegistration() {
        let tabs = [tab("x"), tab("y"), tab("z")]
        let result = SidebarTabOrdering.applied(tabs: tabs, savedOrder: [])
        XCTAssertEqual(ids(result), ["x", "y", "z"])
    }

    func testApplied_unknownTabsKeepRegistrationOrder() {
        // "b" is the only one in saved order; "a" and "c" are unknown.
        let tabs = [tab("a"), tab("b"), tab("c")]
        let result = SidebarTabOrdering.applied(tabs: tabs, savedOrder: ["b"])
        // "b" is known → comes first; "a","c" unknown → keep their relative registration order
        XCTAssertEqual(ids(result), ["b", "a", "c"])
    }

    func testApplied_savedOrderContainsHiddenTabs() {
        // Saved order references tabs not currently visible — they're skipped.
        let tabs = [tab("a"), tab("c")]
        let result = SidebarTabOrdering.applied(
            tabs: tabs,
            savedOrder: ["c", "hidden", "a"])
        XCTAssertEqual(ids(result), ["c", "a"])
    }

    func testApplied_mixOfKnownAndUnknown() {
        let tabs = [tab("new1"), tab("a"), tab("new2"), tab("b")]
        let result = SidebarTabOrdering.applied(
            tabs: tabs,
            savedOrder: ["b", "a"])
        // Known tabs ("b","a") come first in saved order, then unknowns in registration order
        XCTAssertEqual(ids(result), ["b", "a", "new1", "new2"])
    }

    // MARK: - mergeOrder(saved:visible:)

    func testMerge_visibleReorderPreservesHidden() {
        let result = SidebarTabOrdering.mergeOrder(
            saved: ["a", "b", "c", "d"],
            visible: ["c", "a"])
        // Hidden b(idx 1) and d(idx 3) stay pinned; visible c,a fill slots 0,2
        XCTAssertEqual(result, ["c", "b", "a", "d"])
    }

    func testMerge_emptyVisible() {
        let result = SidebarTabOrdering.mergeOrder(
            saved: ["a", "b", "c"],
            visible: [])
        // All hidden → preserve original order
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testMerge_emptySaved() {
        let result = SidebarTabOrdering.mergeOrder(
            saved: [],
            visible: ["x", "y"])
        XCTAssertEqual(result, ["x", "y"])
    }

    func testMerge_visibleContainsNewTab() {
        // A new tab in visible that wasn't in saved; hidden b(idx 1) stays pinned
        let result = SidebarTabOrdering.mergeOrder(
            saved: ["a", "b"],
            visible: ["new", "a"])
        XCTAssertEqual(result, ["new", "b", "a"])
    }

    func testMerge_allVisible() {
        let result = SidebarTabOrdering.mergeOrder(
            saved: ["a", "b", "c"],
            visible: ["c", "b", "a"])
        XCTAssertEqual(result, ["c", "b", "a"])
    }

    // MARK: - Local ↔ Remote scenario

    func testScenario_reorderLocal_switchRemote_switchBack() {
        // Simulate: user has local tabs, reorders them, switches to remote, then back.
        let localTabs = [tab("file-tree-local"), tab("git-panel"), tab("bookmarks")]
        let remoteTabs = [tab("file-tree-remote"), tab("bookmarks")]

        // Step 1: User reorders local tabs → git-panel first
        var saved = SidebarTabOrdering.mergeOrder(
            saved: [],
            visible: ["git-panel", "file-tree-local", "bookmarks"])
        XCTAssertEqual(saved, ["git-panel", "file-tree-local", "bookmarks"])

        // Step 2: Switch to remote — sort remote tabs using saved order.
        // "file-tree-remote" is not in saved order. "bookmarks" is at index 2.
        let remoteSorted = SidebarTabOrdering.applied(
            tabs: remoteTabs, savedOrder: saved)
        // bookmarks is known (index 2), file-tree-remote is unknown → bookmarks first
        XCTAssertEqual(ids(remoteSorted), ["bookmarks", "file-tree-remote"])

        // Step 3: User reorders remote tabs → file-tree-remote first
        saved = SidebarTabOrdering.mergeOrder(
            saved: saved,
            visible: ["file-tree-remote", "bookmarks"])
        // Hidden local tabs should still be preserved
        XCTAssertTrue(saved.contains("git-panel"))
        XCTAssertTrue(saved.contains("file-tree-local"))

        // Step 4: Switch back to local — local order should be preserved
        let localSorted = SidebarTabOrdering.applied(
            tabs: localTabs, savedOrder: saved)
        // git-panel and file-tree-local should keep their relative positions from step 1
        let localIDs = ids(localSorted)
        XCTAssertTrue(
            localIDs.firstIndex(of: "git-panel")! < localIDs.firstIndex(of: "file-tree-local")!,
            "git-panel should still be before file-tree-local after remote round-trip")
    }

    func testScenario_remoteReorderDoesNotLoseLocalPositions() {
        // Start with a saved order from local context
        var saved = ["file-tree-local", "git-panel", "bookmarks", "docker"]

        // Switch to remote with different visible tabs
        // Reorder remote: bookmarks first
        saved = SidebarTabOrdering.mergeOrder(
            saved: saved,
            visible: ["bookmarks", "file-tree-remote"])

        // Local tabs should still be in saved order
        XCTAssertTrue(saved.contains("file-tree-local"))
        XCTAssertTrue(saved.contains("git-panel"))
        XCTAssertTrue(saved.contains("docker"))

        // Switch back to local — hidden local tabs kept their pinned positions,
        // so the original local order is fully preserved.
        let localTabs = [
            tab("file-tree-local"), tab("git-panel"),
            tab("bookmarks"), tab("docker")
        ]
        let sorted = SidebarTabOrdering.applied(tabs: localTabs, savedOrder: saved)
        let sortedIDs = ids(sorted)

        XCTAssertEqual(
            sortedIDs, ["file-tree-local", "git-panel", "bookmarks", "docker"],
            "Local tab order should be unchanged by remote-only reorder")
    }

    /// Exact user-reported scenario:
    /// Local: [file-tree-local, bookmarks, snippets]
    /// SSH remote → [bookmarks, snippets, file-tree-remote]
    /// Drag file-tree-remote to first → [file-tree-remote, bookmarks, snippets]
    /// Exit remote → local should still show file-tree-local first
    func testScenario_moveRemoteExplorerToFront_localExplorerStaysFirst() {
        let localTabs = [tab("file-tree-local"), tab("bookmarks"), tab("snippets")]
        _ = [tab("bookmarks"), tab("snippets"), tab("file-tree-remote")]

        // Initial saved order from local context
        var saved = ["file-tree-local", "bookmarks", "snippets"]

        // User drags file-tree-remote to first position on remote
        saved = SidebarTabOrdering.mergeOrder(
            saved: saved,
            visible: ["file-tree-remote", "bookmarks", "snippets"])

        // file-tree-local must still be in saved order
        XCTAssertTrue(
            saved.contains("file-tree-local"),
            "file-tree-local must not be lost from saved order")

        // Exit remote → display local tabs
        let sorted = SidebarTabOrdering.applied(tabs: localTabs, savedOrder: saved)
        let sortedIDs = ids(sorted)

        // file-tree-local should be first (it was first before remote session)
        XCTAssertEqual(
            sortedIDs, ["file-tree-local", "bookmarks", "snippets"],
            "Local file explorer should remain at front after remote reorder")
    }
}
