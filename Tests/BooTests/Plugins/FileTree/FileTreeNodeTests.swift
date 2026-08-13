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
        root.refreshAll()
        XCTAssertEqual(subNode.children?.count, 1, "refreshAll must reload expanded subdirectories")
    }

    /// A no-op refresh must leave treeRevision alone.
    func testRefreshAllIsQuietWhenNothingChanged() throws {
        try Data().write(to: tmpDir.appendingPathComponent("a.txt"))
        let root = makeRoot()
        root.loadChildren()
        let revision = root.treeRevision

        root.refreshAll()
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
        fresh.restoreExpanded(paths)
        let freshSub = try XCTUnwrap(fresh.children?.first { $0.name == "sub" })
        XCTAssertTrue(freshSub.isExpanded)
        let freshNested = try XCTUnwrap(freshSub.children?.first { $0.name == "nested" })
        XCTAssertTrue(freshNested.isExpanded, "Nested expansion must restore too")
    }
}
