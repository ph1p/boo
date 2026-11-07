import XCTest

@testable import Boo

@MainActor
final class FileTreeStickyTests: XCTestCase {
    /// /r: a/ (open: a1/ (open: x, y), a2), b
    private func makeRows() -> [FileTreeView.FlatRow] {
        let root = FileTreeNode(name: "r", path: "/r", isDirectory: true)
        root.applyListing([
            .init(name: "a", path: "/r/a", isDir: true),
            .init(name: "b", path: "/r/b", isDir: false)
        ])
        let a = root.children![0]
        a.isExpanded = true
        a.applyListing([
            .init(name: "a1", path: "/r/a/a1", isDir: true),
            .init(name: "a2", path: "/r/a/a2", isDir: false)
        ])
        let a1 = a.children![0]
        a1.isExpanded = true
        a1.applyListing([
            .init(name: "x", path: "/r/a/a1/x", isDir: false),
            .init(name: "y", path: "/r/a/a1/y", isDir: false)
        ])
        return FileTreeRowCache().rows(for: root, showHidden: false).rows
    }

    private func names(_ rows: [FileTreeView.FlatRow]) -> [String] { rows.map(\.node.name) }

    private func pinned(_ topIndex: Int, in rows: [FileTreeView.FlatRow]? = nil) -> [String] {
        names(FileTreeSticky.pinnedRows(rows ?? makeRows(), topIndex: topIndex))
    }

    func testRowOrder() {
        XCTAssertEqual(names(makeRows()), ["a", "a1", "x", "y", "a2", "b"])
    }

    func testNothingPinnedAtTop() {
        XCTAssertEqual(pinned(0), [])
    }

    /// Scrolled to `a1`: `a` is pinned, which covers `a1`, so `a1` is pinned too.
    func testPinsAncestorsOfRowBelowHeader() {
        XCTAssertEqual(pinned(1), ["a", "a1"])
    }

    /// Past the open folder, only the folders still containing the rows below stay pinned.
    func testUnpinsFolderOnceScrolledPast() {
        XCTAssertEqual(pinned(3), ["a"])
        XCTAssertEqual(pinned(5), [])
    }

    func testOutOfRangeIndexIsClamped() {
        XCTAssertEqual(pinned(99), [])
        XCTAssertEqual(pinned(3, in: []), [])
    }

    /// A revealed row lands just below its pinned folders, never under them.
    func testRevealTopKeepsRowBelowHeader() {
        let rows = makeRows()
        XCTAssertEqual(FileTreeSticky.topIndex(revealing: 0, in: rows), 0)
        XCTAssertEqual(FileTreeSticky.topIndex(revealing: 1, in: rows), 0)  // a1
        XCTAssertEqual(FileTreeSticky.topIndex(revealing: 2, in: rows), 0)  // x
        XCTAssertEqual(FileTreeSticky.topIndex(revealing: 3, in: rows), 2)  // y under [a]
        XCTAssertEqual(FileTreeSticky.topIndex(revealing: 5, in: rows), 5)  // b
        for index in rows.indices {
            let top = FileTreeSticky.topIndex(revealing: index, in: rows)
            XCTAssertFalse(FileTreeSticky.isCovered(index, in: rows, topIndex: top), "row \(index)")
        }
    }

    func testCoveredRows() {
        let rows = makeRows()
        XCTAssertTrue(FileTreeSticky.isCovered(2, in: rows, topIndex: 2))  // x under [a]
        XCTAssertFalse(FileTreeSticky.isCovered(3, in: rows, topIndex: 2))
        XCTAssertTrue(FileTreeSticky.isCovered(0, in: rows, topIndex: 2))  // above the view
        XCTAssertFalse(FileTreeSticky.isCovered(0, in: rows, topIndex: 0))
    }

    func testRowCacheIndexesRowIDs() {
        let cache = FileTreeRowCache()
        let root = FileTreeNode(name: "r", path: "/r", isDirectory: true)
        root.applyListing([.init(name: "a", path: "/r/a", isDir: false)])
        let rows = cache.rows(for: root, showHidden: false).rows
        XCTAssertEqual(cache.index(of: rows[0].id), 0)
        XCTAssertNil(cache.index(of: "/nope"))
    }
}
