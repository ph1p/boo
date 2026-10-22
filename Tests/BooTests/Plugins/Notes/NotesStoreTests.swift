import XCTest

@testable import Boo

final class NotesStoreTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("notes-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testFileNameHashesStandardizedFolder() {
        let id = UUID()
        let a = NotesStore.fileName(folderPath: "/Users/me/proj", workspaceID: id)
        XCTAssertEqual(a, NotesStore.fileName(folderPath: "/Users/me/proj/", workspaceID: UUID()))
        XCTAssertEqual(a, NotesStore.fileName(folderPath: "/Users/me/./proj", workspaceID: id))
        XCTAssertNotEqual(a, NotesStore.fileName(folderPath: "/Users/me/other", workspaceID: id))
        XCTAssertTrue(a.hasSuffix(".md"))
        XCTAssertEqual(a.count, 40 + 3)
    }

    func testFileNameFallsBackToWorkspaceID() {
        let id = UUID()
        XCTAssertEqual(NotesStore.fileName(folderPath: "", workspaceID: id), id.uuidString.lowercased() + ".md")
    }

    func testAppendBlockUsesLongerFence() {
        let date = Date(timeIntervalSince1970: 0)
        let block = NotesStore.appendBlock("a ``` b\n", date: date)
        XCTAssertTrue(block.contains("\n````\na ``` b\n````\n"), block)
        XCTAssertTrue(block.hasPrefix("_"))
    }

    func testAppendCreatesAndSeparates() throws {
        let path = NotesStore.path(folderPath: "/x", workspaceID: UUID(), in: dir)
        XCTAssertTrue(NotesStore.append("one", to: path))
        try "\(try String(contentsOfFile: path, encoding: .utf8))tail".write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(NotesStore.append("two", to: path))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("```\none\n```\n"))
        XCTAssertTrue(text.contains("tail\n\n_"), text)
        XCTAssertTrue(text.hasSuffix("```\ntwo\n```\n"))
    }

    func testAppendBlockHeaderNamesCommandAndCwd() {
        let block = NotesStore.appendBlock(
            "out", command: "make test", cwd: NSHomeDirectory() + "/proj", date: Date(timeIntervalSince1970: 0))
        let lines = block.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasSuffix("_ · `~/proj`"), lines[0])
        XCTAssertTrue(block.contains("```\n$ make test\nout\n```\n"), block)
    }

    func testRememberTitlesBatchesAndSkipsScratch() {
        let a = NotesStore.path(folderPath: "/a", workspaceID: UUID(), in: dir)
        let b = NotesStore.path(folderPath: "/b", workspaceID: UUID(), in: dir)
        NotesStore.rememberTitles([(a, "A"), (b, "B"), (NotesStore.scratchPath(in: dir), "Nope")])
        XCTAssertTrue(NotesStore.append("x", to: a))
        XCTAssertTrue(NotesStore.append("y", to: b))
        XCTAssertTrue(NotesStore.append("z", to: NotesStore.scratchPath(in: dir)))
        XCTAssertEqual(Set(NotesStore.list(in: dir).map(\.title)), [NotesStore.scratchTitle, "A", "B"])
    }

    func testListTitlesScratchFirstThenRecent() throws {
        let old = NotesStore.path(folderPath: "/old", workspaceID: UUID(), in: dir)
        let new = NotesStore.path(folderPath: "/new", workspaceID: UUID(), in: dir)
        XCTAssertTrue(NotesStore.append("a", to: old))
        XCTAssertTrue(NotesStore.append("b", to: new))
        XCTAssertTrue(NotesStore.append("c", to: NotesStore.scratchPath(in: dir)))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old)
        NotesStore.rememberTitle("New WS", for: new)

        let notes = NotesStore.list(in: dir)
        XCTAssertEqual(
            notes.map(\.title),
            [
                NotesStore.scratchTitle, "New WS", String((old as NSString).lastPathComponent.dropLast(3))
            ])
    }

    func testSearchFindsLinesAcrossNotes() throws {
        let a = (dir as NSString).appendingPathComponent("a.md")
        let b = (dir as NSString).appendingPathComponent("b.md")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "intro\n  Deploy steps\nend".write(toFile: a, atomically: true, encoding: .utf8)
        try "nothing\nredeploy".write(toFile: b, atomically: true, encoding: .utf8)

        let matches = NotesStore.search("DEPLOY", in: dir)
        XCTAssertEqual(
            Set(matches.map { "\(($0.path as NSString).lastPathComponent):\($0.line):\($0.text)" }),
            ["a.md:2:Deploy steps", "b.md:2:redeploy"])
        XCTAssertEqual(NotesStore.search("deploy", in: dir, limit: 1).count, 1)
        XCTAssertTrue(NotesStore.search("  ", in: dir).isEmpty)
    }
}
