import XCTest

@testable import Boo

/// Covers `FileTreeNode.refresh(changedDirs:)` — the path-scoped alternative to
/// `refreshAll()`, which exists so an FS-event burst in one directory does not re-walk
/// every expanded directory in the tree.
final class FileTreeNodeScopedRefreshTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTreeNodeScopedRefreshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func mkdir(_ relative: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    /// Build a loaded root whose named subdirectories are expanded and loaded.
    private func makeRoot(expanding names: [String] = []) throws -> FileTreeNode {
        let root = FileTreeNode(
            name: tmpDir.lastPathComponent, path: tmpDir.path, isDirectory: true)
        root.root = root
        root.isExpanded = true
        root.loadChildren()
        for name in names {
            let node = try XCTUnwrap(root.children?.first { $0.name == name })
            node.isExpanded = true
            node.loadChildren()
        }
        return root
    }

    private func child(_ root: FileTreeNode, _ name: String) throws -> FileTreeNode {
        try XCTUnwrap(root.children?.first { $0.name == name })
    }

    // MARK: - Scoping

    /// A file created directly in the root shows up when the root's own path is named.
    func testRefreshPicksUpNewFileInNamedDirectory() throws {
        let root = try makeRoot()
        XCTAssertEqual(root.children?.count, 0)

        try touch(tmpDir.appendingPathComponent("new.txt"))
        root.refresh(changedDirs: [tmpDir.path])

        XCTAssertEqual(
            root.children?.map(\.name), ["new.txt"],
            "The directory named by the event must be re-read")
    }

    /// An expanded subdirectory refreshes when its own path is in the batch, even though
    /// the batch never names the root.
    func testRefreshReachesExpandedDescendant() throws {
        let sub = try mkdir("sub")
        let root = try makeRoot(expanding: ["sub"])
        let subNode = try child(root, "sub")
        XCTAssertEqual(subNode.children?.count, 0)

        try touch(sub.appendingPathComponent("deep.txt"))
        root.refresh(changedDirs: [sub.path])

        XCTAssertEqual(
            subNode.children?.map(\.name), ["deep.txt"],
            "A descendant named in the batch must be re-read")
    }

    /// The point of the scoping: a burst confined to one subtree must leave a sibling
    /// subtree's already-loaded children untouched.
    func testRefreshSkipsUnrelatedSibling() throws {
        let noisy = try mkdir("noisy")
        let quiet = try mkdir("quiet")
        let root = try makeRoot(expanding: ["noisy", "quiet"])
        let quietNode = try child(root, "quiet")
        XCTAssertEqual(quietNode.children?.count, 0)

        // Both directories gain a file, but only `noisy` is reported as changed.
        try touch(noisy.appendingPathComponent("build.log"))
        try touch(quiet.appendingPathComponent("unseen.txt"))
        root.refresh(changedDirs: [noisy.path])

        XCTAssertEqual(
            try child(root, "noisy").children?.map(\.name), ["build.log"],
            "The reported directory must refresh")
        XCTAssertEqual(
            quietNode.children?.count, 0,
            "An unreported sibling must not be re-read, even though its contents changed")
    }

    /// A collapsed directory is not walked — its children are re-read when it is expanded.
    func testRefreshSkipsCollapsedDescendant() throws {
        let sub = try mkdir("sub")
        let root = try makeRoot(expanding: ["sub"])
        let subNode = try child(root, "sub")
        subNode.isExpanded = false

        try touch(sub.appendingPathComponent("later.txt"))
        root.refresh(changedDirs: [sub.path])

        XCTAssertEqual(
            subNode.children?.count, 0,
            "A collapsed directory need not be refreshed — nothing is on screen")
    }

    /// An event outside the tree entirely must be a no-op, not a full walk.
    func testRefreshIgnoresPathsOutsideTheTree() throws {
        let root = try makeRoot()
        let revisionBefore = root.treeRevision

        try touch(tmpDir.appendingPathComponent("appeared.txt"))
        root.refresh(changedDirs: ["/some/other/place"])

        XCTAssertEqual(root.children?.count, 0, "An unrelated path must not trigger a re-read")
        XCTAssertEqual(root.treeRevision, revisionBefore)
    }

    /// A sibling directory whose name merely shares a prefix with a changed path must not
    /// be treated as inside it (`/a/src` vs `/a/src-gen`).
    func testRefreshDoesNotMatchPrefixSiblings() throws {
        _ = try mkdir("src")
        let srcGen = try mkdir("src-gen")
        let root = try makeRoot(expanding: ["src", "src-gen"])
        let srcGenNode = try child(root, "src-gen")

        try touch(srcGen.appendingPathComponent("generated.swift"))
        root.refresh(changedDirs: [tmpDir.appendingPathComponent("src").path])

        XCTAssertEqual(
            srcGenNode.children?.count, 0,
            "`src-gen` is not inside `src` — a prefix match must not reach it")
    }

    /// Expanded folders must survive a refresh, or the tree would collapse on every
    /// FS event.
    func testRefreshPreservesExpansion() throws {
        let sub = try mkdir("sub")
        _ = try mkdir("sub/nested")
        let root = try makeRoot(expanding: ["sub"])
        let nested = try XCTUnwrap(
            try child(root, "sub").children?.first { $0.name == "nested" })
        nested.isExpanded = true
        nested.loadChildren()

        try touch(sub.appendingPathComponent("sibling.txt"))
        root.refresh(changedDirs: [sub.path])

        let nestedAfter = try XCTUnwrap(
            try child(root, "sub").children?.first { $0.name == "nested" })
        XCTAssertTrue(nestedAfter.isExpanded, "A refresh must not collapse open folders")
    }

    /// A structural change bumps the root's revision so the view re-flattens the tree.
    func testRefreshBumpsTreeRevisionOnStructuralChange() throws {
        let root = try makeRoot()
        let before = root.treeRevision

        try touch(tmpDir.appendingPathComponent("added.txt"))
        root.refresh(changedDirs: [tmpDir.path])

        XCTAssertGreaterThan(
            root.treeRevision, before, "Adding a row must bump the revision the view watches")
    }

    /// Refreshing a file node (not a directory) is a no-op rather than a crash.
    func testRefreshOnFileNodeIsNoOp() throws {
        try touch(tmpDir.appendingPathComponent("plain.txt"))
        let root = try makeRoot()
        let fileNode = try child(root, "plain.txt")
        fileNode.refresh(changedDirs: [fileNode.path])
        XCTAssertNil(fileNode.children)
    }
}
