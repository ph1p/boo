import XCTest

@testable import Boo

final class FileTreeNodeTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTreeNodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Run an async tree operation and wait for its completion.
    private func wait(_ operation: (@escaping FileTreeNode.Completion) -> Void) {
        let done = expectation(description: "tree operation")
        operation { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func makeRoot() -> FileTreeNode {
        let root = FileTreeNode(name: tmpDir.lastPathComponent, path: tmpDir.path, isDirectory: true)
        root.isExpanded = true
        return root
    }

    /// Reloading an unchanged directory must not bump treeRevision — otherwise a
    /// churning watched directory re-flattens the whole tree on every FS event.
    func testLoadChildrenDoesNotBumpRevisionWhenUnchanged() throws {
        try Data().write(to: tmpDir.appendingPathComponent("a.txt"))
        let root = makeRoot()
        root.loadChildren()
        let revision = root.treeRevision

        root.loadChildren()
        XCTAssertEqual(root.treeRevision, revision, "Unchanged reload must not bump treeRevision")
    }

    func testLoadChildrenBumpsRevisionWhenFileAdded() throws {
        try Data().write(to: tmpDir.appendingPathComponent("a.txt"))
        let root = makeRoot()
        root.loadChildren()
        let revision = root.treeRevision

        try Data().write(to: tmpDir.appendingPathComponent("b.txt"))
        root.loadChildren()
        XCTAssertNotEqual(root.treeRevision, revision, "A new file must bump treeRevision")
    }

    func testLoadChildrenBumpsRevisionWhenFileRemoved() throws {
        let file = tmpDir.appendingPathComponent("a.txt")
        try Data().write(to: file)
        try Data().write(to: tmpDir.appendingPathComponent("b.txt"))
        let root = makeRoot()
        root.loadChildren()
        let revision = root.treeRevision

        try FileManager.default.removeItem(at: file)
        root.loadChildren()
        XCTAssertNotEqual(root.treeRevision, revision, "A removed file must bump treeRevision")
    }

    /// Existing child nodes must be reused across reloads so their expansion state
    /// (and SwiftUI identity) survives a refresh.
    func testLoadChildrenReusesExistingNodes() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = makeRoot()
        root.loadChildren()
        let subNode = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        subNode.isExpanded = true

        try Data().write(to: tmpDir.appendingPathComponent("new.txt"))
        root.loadChildren()

        let subNode2 = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        XCTAssertTrue(subNode2 === subNode, "Reload must reuse the existing directory node")
        XCTAssertTrue(subNode2.isExpanded, "Reload must not collapse an expanded folder")
    }

    /// refreshAll walks expanded subdirectories and picks up nested changes.
    func testRefreshAllPicksUpNestedChanges() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = makeRoot()
        root.loadChildren()
        let subNode = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        subNode.isExpanded = true
        subNode.loadChildren()
        XCTAssertEqual(subNode.children?.count, 0)

        try Data().write(to: sub.appendingPathComponent("nested.txt"))
        wait { root.refreshAll(completion: $0) }
        XCTAssertEqual(subNode.children?.count, 1, "refreshAll must reload expanded subdirectories")
    }

    /// A no-op refresh must leave treeRevision alone.
    func testRefreshAllIsQuietWhenNothingChanged() throws {
        try Data().write(to: tmpDir.appendingPathComponent("a.txt"))
        let root = makeRoot()
        root.loadChildren()
        let revision = root.treeRevision

        wait { root.refreshAll(completion: $0) }
        XCTAssertEqual(root.treeRevision, revision, "No-op refresh must not bump treeRevision")
    }

    func testExpandedPathsRoundTrip() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = makeRoot()
        root.loadChildren()
        let subNode = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        subNode.isExpanded = true
        subNode.loadChildren()
        let nestedNode = try XCTUnwrap(subNode.children?.first { $0.name == "nested" })
        nestedNode.isExpanded = true

        let paths = root.expandedPaths()
        XCTAssertTrue(paths.contains(subNode.path))
        XCTAssertTrue(paths.contains(nestedNode.path))

        // A fresh tree restores the same expansion.
        let fresh = makeRoot()
        fresh.loadChildren()
        wait { fresh.restoreExpanded(paths, completion: $0) }
        let freshSub = try XCTUnwrap(fresh.children?.first { $0.name == "sub" })
        XCTAssertTrue(freshSub.isExpanded)
        let freshNested = try XCTUnwrap(freshSub.children?.first { $0.name == "nested" })
        XCTAssertTrue(freshNested.isExpanded, "Nested expansion must restore too")
    }

    /// Collapsing a folder drops the listings of collapsed folders below it but keeps
    /// its own listing and its expanded descendants, so re-expanding restores them.
    func testCollapseReleasesHiddenListings() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir.appendingPathComponent("a/open/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("a/closed/x"), withIntermediateDirectories: true)
        let root = makeRoot()
        root.loadChildren()
        let a = try XCTUnwrap(root.children?.first { $0.name == "a" })
        a.isExpanded = true
        a.loadChildren()
        let open = try XCTUnwrap(a.children?.first { $0.name == "open" })
        let closed = try XCTUnwrap(a.children?.first { $0.name == "closed" })
        open.isExpanded = true
        open.loadChildren()
        closed.loadChildren()

        a.collapse()
        XCTAssertNotNil(a.children, "The collapsed folder keeps its own listing")
        XCTAssertNil(closed.children, "A collapsed descendant's listing is released")
        XCTAssertNotNil(open.children, "An expanded descendant keeps its listing")
        XCTAssertTrue(open.isExpanded)
    }

    /// Re-expanding a folder re-reads expanded descendants, whose listings went stale
    /// while hidden.
    func testExpandRefreshesExpandedDescendants() throws {
        let nested = tmpDir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = makeRoot()
        root.loadChildren()
        let a = try XCTUnwrap(root.children?.first { $0.name == "a" })
        a.isExpanded = true
        a.loadChildren()
        let b = try XCTUnwrap(a.children?.first { $0.name == "b" })
        b.isExpanded = true
        b.loadChildren()
        a.collapse()

        try Data().write(to: nested.appendingPathComponent("new.txt"))
        a.expand()
        let landed = expectation(description: "descendant reloaded")
        func poll() {
            if b.children?.count == 1 { return landed.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(b.children?.map(\.name), ["new.txt"])
    }

    /// The row cache reuses its flattening until the tree's revision changes.
    func testRowCacheRebuildsOnlyOnRevisionChange() throws {
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data().write(to: tmpDir.appendingPathComponent("sub/inner.txt"))
        try Data().write(to: tmpDir.appendingPathComponent(".hidden"))
        let root = makeRoot()
        root.loadChildren()
        let cache = FileTreeRowCache()

        XCTAssertEqual(
            cache.rows(for: root, showHidden: false).order.map { ($0 as NSString).lastPathComponent }, ["sub"])
        XCTAssertEqual(cache.rows(for: root, showHidden: true).order.count, 2)

        let sub = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        sub.isExpanded = true
        sub.loadChildren()
        XCTAssertEqual(
            cache.rows(for: root, showHidden: false).order.map { ($0 as NSString).lastPathComponent },
            ["sub", "inner.txt"], "A revision bump re-flattens")
    }
}
