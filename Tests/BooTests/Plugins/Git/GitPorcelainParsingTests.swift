import XCTest

@testable import Boo

/// `-z` output parsing for the Git sidebar and agent diff stats. Without `-z`,
/// git quotes non-ASCII paths and prints renames as `old -> new`.
final class GitPorcelainParsingTests: XCTestCase {

    func testStatusKeepsRenameTargetAndNonASCIIPath() {
        let output = "R  new.txt\0old.txt\0 M ä b.txt\0?? dir/x\0"
        let files = GitPlugin.parseChangedFiles(porcelainZ: output, repoRoot: "/repo")
        XCTAssertEqual(files.map(\.path), ["new.txt", "ä b.txt", "dir/x"])
        XCTAssertEqual(files[0].indexStatus, "R")
        XCTAssertEqual(files[1].workTreeStatus, "M")
        XCTAssertEqual(files[1].fullPath, "/repo/ä b.txt")
    }

    func testNumstatRenameUsesNewPath() {
        let output = "0\t0\t\0old.txt\0new.txt\01\t2\tä b.txt\0-\t-\timg.png\0"
        let entries = parseNumstatZ(output, repoRoot: "/repo")
        XCTAssertEqual(entries.map(\.path), ["new.txt", "ä b.txt", "img.png"])
        XCTAssertEqual(entries[1].insertions, 1)
        XCTAssertEqual(entries[1].deletions, 2)
        XCTAssertEqual(entries[2].insertions, 0, "binary files report '-'")
    }
}
