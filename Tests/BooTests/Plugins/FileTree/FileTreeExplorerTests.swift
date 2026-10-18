import XCTest

@testable import Boo

// MARK: - Git status

final class FileTreeGitStatusTests: XCTestCase {
    private let root = "/repo"

    func testPorcelainMapping() {
        XCTAssertEqual(FileGitStatus(x: " ", y: "M"), .modified)
        XCTAssertEqual(FileGitStatus(x: "M", y: " "), .modified)
        XCTAssertEqual(FileGitStatus(x: "A", y: " "), .added)
        XCTAssertEqual(FileGitStatus(x: " ", y: "D"), .deleted)
        XCTAssertEqual(FileGitStatus(x: "R", y: " "), .renamed)
        XCTAssertEqual(FileGitStatus(x: "U", y: "U"), .conflicted)
        XCTAssertEqual(FileGitStatus(x: "A", y: "A"), .conflicted)
        XCTAssertEqual(FileGitStatus(x: "?", y: "?"), .untracked)
        XCTAssertEqual(FileGitStatus(x: "!", y: "!"), .ignored)
        XCTAssertNil(FileGitStatus(x: " ", y: " "))
    }

    func testParsesEntriesAndSkipsRenameSource() {
        let output = " M src/a.swift\0R  new.txt\0old.txt\0?? notes/\0!! build/\0"
        let status = FileTreeGitStatus(repoRoot: root, porcelainZ: output)
        XCTAssertEqual(status.status(for: "/repo/src/a.swift", isDirectory: false), .modified)
        XCTAssertEqual(status.status(for: "/repo/new.txt", isDirectory: false), .renamed)
        XCTAssertNil(
            status.status(for: "/repo/old.txt", isDirectory: false),
            "Rename source must not be parsed as an entry")
        XCTAssertEqual(status.status(for: "/repo/notes", isDirectory: true), .untracked)
    }

    func testUntrackedAndIgnoredFoldersAreInherited() {
        let status = FileTreeGitStatus(repoRoot: root, porcelainZ: "?? notes/\0!! build/\0")
        XCTAssertEqual(status.status(for: "/repo/notes/deep/x.md", isDirectory: false), .untracked)
        XCTAssertEqual(status.status(for: "/repo/build/out.o", isDirectory: false), .ignored)
        XCTAssertNil(status.status(for: "/repo/clean.txt", isDirectory: false))
    }

    func testFolderRollupKeepsStrongestAndIgnoresIgnored() {
        let output = "?? src/new.swift\0 M src/ui/view.swift\0!! src/cache/\0"
        let status = FileTreeGitStatus(repoRoot: root, porcelainZ: output)
        XCTAssertEqual(status.status(for: "/repo/src", isDirectory: true), .modified)
        XCTAssertEqual(status.status(for: "/repo/src/ui", isDirectory: true), .modified)
        XCTAssertEqual(status.status(for: "/repo", isDirectory: true), .modified)
        XCTAssertEqual(status.status(for: "/repo/src/cache", isDirectory: true), .ignored)
        XCTAssertNil(status.status(for: "/repo/other", isDirectory: true))
    }

    /// End to end against a real repo in a temp dir — exercises the path-form mapping
    /// (`/var` vs `/private/var`) and a tree root below the repo root.
    func testLoadFromRealRepo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTreeGitStatusTests-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard runGit(["init", "-q"], in: dir) else { throw XCTSkip("git unavailable") }
        try "x".write(to: sub.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(runGit(["add", "."], in: dir))
        XCTAssertTrue(
            runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: dir))
        try "y".write(to: sub.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "z".write(to: sub.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let status = try XCTUnwrap(FileTreeGitStatus.load(rootPath: sub.path))
        XCTAssertEqual(status.repoRoot, dir.path)
        let tracked = sub.appendingPathComponent("tracked.txt").path
        let added = sub.appendingPathComponent("new.txt").path
        XCTAssertEqual(status.status(for: tracked, isDirectory: false), .modified)
        XCTAssertEqual(status.status(for: added, isDirectory: false), .untracked)
        XCTAssertEqual(status.status(for: sub.path, isDirectory: true), .modified)
    }

    func testLoadOutsideRepoIsNil() throws {
        let dir = URL(fileURLWithPath: "/")
        XCTAssertNil(FileTreeGitStatus.load(rootPath: dir.path))
    }

    private func runGit(_ args: [String], in dir: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", dir.path] + args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

// MARK: - Filter

final class FileTreeFilterTests: XCTestCase {
    private func entry(_ rel: String, dir: Bool = false) -> FileTreeIndexEntry {
        FileTreeIndexEntry(name: (rel as NSString).lastPathComponent, relativePath: rel, isDirectory: dir)
    }

    func testEntriesFromRelativeFilesDeriveFolders() {
        let entries = FileTreeIndex.entries(
            fromRelativeFiles: ["a/b/c.swift", "a/d.swift", "top.md"], showHidden: true, limit: 100)
        XCTAssertEqual(
            entries.map(\.relativePath), ["a", "a/b", "a/b/c.swift", "a/d.swift", "top.md"])
        XCTAssertEqual(entries.filter(\.isDirectory).map(\.relativePath), ["a", "a/b"])
    }

    func testEntriesSkipHiddenComponents() {
        let entries = FileTreeIndex.entries(
            fromRelativeFiles: [".github/ci.yml", "src/.env", "src/main.swift"], showHidden: false, limit: 100)
        XCTAssertEqual(entries.map(\.relativePath), ["src", "src/main.swift"])
    }

    func testWalkWithoutGitSkipsHeavyFolders() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTreeFilterTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("node_modules/pkg/index.js"))
        try Data().write(to: dir.appendingPathComponent("src/app.swift"))
        defer { try? fm.removeItem(at: dir) }

        let rels = Set(FileTreeIndex.build(rootPath: dir.path, showHidden: false).map(\.relativePath))
        XCTAssertTrue(rels.contains("src/app.swift"))
        XCTAssertTrue(rels.contains("src"))
        XCTAssertFalse(rels.contains { $0.hasPrefix("node_modules") })
    }

    func testFuzzySubsequenceAndHighlights() throws {
        let match = try XCTUnwrap(FileTreeFuzzy.match("ftv", entry("Boo/FileTreeView.swift")))
        XCTAssertEqual(match.nameHighlights, [0, 4, 8])
        XCTAssertNil(FileTreeFuzzy.match("zzz", entry("Boo/FileTreeView.swift")))
    }

    func testPathQueryMatchesRelativePath() throws {
        let match = try XCTUnwrap(FileTreeFuzzy.match("boo/view", entry("Boo/FileTreeView.swift")))
        XCTAssertTrue(match.nameHighlights.isEmpty)
    }

    func testRankPrefersPrefixAndShallowPaths() {
        let index = [
            entry("docs/deep/readme.md"), entry("readme.md"), entry("src/thread_mode.swift")
        ]
        let ranked = FileTreeFuzzy.rank("readme", in: index).map(\.entry.relativePath)
        XCTAssertEqual(ranked.first, "readme.md")
        XCTAssertEqual(ranked.dropFirst().first, "docs/deep/readme.md")
    }

    func testRankHonorsLimit() {
        let index = (0..<50).map { entry("file\($0).txt") }
        XCTAssertEqual(FileTreeFuzzy.rank("file", in: index, limit: 10).count, 10)
    }
}

// MARK: - Selection

@MainActor
final class FileTreeSelectionTests: XCTestCase {
    private let order = ["/a", "/b", "/c", "/d"]

    func testPlainToggleAndExtendClicks() {
        let sel = FileTreeSelection()
        sel.click("/b", kind: .plain, order: order)
        XCTAssertEqual(sel.selected, ["/b"])
        sel.click("/d", kind: .extend, order: order)
        XCTAssertEqual(sel.selected, ["/b", "/c", "/d"])
        sel.click("/c", kind: .toggle, order: order)
        XCTAssertEqual(sel.selected, ["/b", "/d"])
        sel.click("/a", kind: .toggle, order: order)
        XCTAssertEqual(sel.ordered(in: order), ["/a", "/b", "/d"])
    }

    func testMoveClampsAndExtends() {
        let sel = FileTreeSelection()
        sel.move(by: 1, order: order, extend: false)
        XCTAssertEqual(sel.cursor, "/a", "First move with no cursor lands on the first row")
        sel.move(by: -1, order: order, extend: false)
        XCTAssertEqual(sel.cursor, "/a")
        sel.move(by: 1, order: order, extend: true)
        sel.move(by: 1, order: order, extend: true)
        XCTAssertEqual(sel.selected, ["/a", "/b", "/c"])
        XCTAssertEqual(sel.cursor, "/c")
        sel.move(by: -1, order: order, extend: true)
        XCTAssertEqual(sel.selected, ["/a", "/b"], "Shrinking toward the anchor drops rows")
    }

    func testSelectAllAndPrune() {
        let sel = FileTreeSelection()
        sel.selectAll(order: order)
        XCTAssertEqual(sel.selected.count, 4)
        sel.select("/c")
        sel.prune(visible: ["/a", "/b"])
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertNil(sel.cursor)
    }
}

// MARK: - Node reveal / collapse / async load

@MainActor
final class FileTreeNodeNavigationTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTreeNodeNavigationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data().write(to: tmpDir.appendingPathComponent("a/b/file.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeRoot() -> FileTreeNode {
        let root = FileTreeNode(name: tmpDir.lastPathComponent, path: tmpDir.path, isDirectory: true)
        root.isExpanded = true
        root.loadChildren()
        return root
    }

    private func child(_ node: FileTreeNode?, _ name: String) -> FileTreeNode? {
        node?.children?.first { $0.name == name }
    }

    func testRevealExpandsAncestors() {
        let root = makeRoot()
        XCTAssertTrue(root.reveal(tmpDir.appendingPathComponent("a/b/file.txt").path))
        let a = child(root, "a")
        let b = child(a, "b")
        XCTAssertEqual(a?.isExpanded, true)
        XCTAssertEqual(b?.isExpanded, true)
        XCTAssertNotNil(child(b, "file.txt"))
    }

    func testRevealOutsideRootFails() {
        XCTAssertFalse(makeRoot().reveal("/definitely/not/here"))
    }

    func testCollapseAllCollapsesDescendants() {
        let root = makeRoot()
        root.reveal(tmpDir.appendingPathComponent("a/b/file.txt").path)
        root.collapseAll()
        XCTAssertEqual(child(root, "a")?.isExpanded, false)
        XCTAssertEqual(child(child(root, "a"), "b")?.isExpanded, false)
        XCTAssertTrue(root.isExpanded, "The root itself stays open")
    }

    func testLoadChildrenAsyncPopulates() async throws {
        let root = makeRoot()
        let a = try XCTUnwrap(child(root, "a"))
        XCTAssertNil(a.children)
        a.loadChildrenAsync()
        for _ in 0..<100 where a.children == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(a.children?.map(\.name), ["b"])
        XCTAssertFalse(a.isLoading)
    }
}
