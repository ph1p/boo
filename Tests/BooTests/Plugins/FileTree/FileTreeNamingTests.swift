import XCTest

@testable import Boo

final class FileTreeNamingTests: XCTestCase {
    func testPlainNameIsKept() {
        XCTAssertEqual(
            FileTreeNaming.target("  notes.md ", allowNesting: false),
            FileTreeNaming.Target(path: "notes.md", forcesDirectory: false))
    }

    func testNamesWithDotsAreAllowed() {
        XCTAssertEqual(FileTreeNaming.target("a..b", allowNesting: false)?.path, "a..b")
        XCTAssertEqual(FileTreeNaming.target(".env", allowNesting: false)?.path, ".env")
    }

    func testRejectsEmptyAndEscapingNames() {
        for input in ["", "   ", ".", "..", "a/../b", "./a", "a\0b"] {
            XCTAssertNil(FileTreeNaming.target(input, allowNesting: true), input)
        }
    }

    func testNestingOnlyWhenAllowed() {
        XCTAssertNil(FileTreeNaming.target("a/b.txt", allowNesting: false))
        XCTAssertEqual(
            FileTreeNaming.target("/a//b/c.txt", allowNesting: true),
            FileTreeNaming.Target(path: "a/b/c.txt", forcesDirectory: false))
    }

    func testTrailingSlashForcesFolder() {
        XCTAssertEqual(
            FileTreeNaming.target("src/utils/", allowNesting: true),
            FileTreeNaming.Target(path: "src/utils", forcesDirectory: true))
    }
}
