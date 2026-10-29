import XCTest

@testable import Boo

final class ScrollbackStoreTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("scrollback-\(UUID().uuidString)")
        ScrollbackStore._testDirectory = dir
    }

    override func tearDown() {
        ScrollbackStore.clear()
        ScrollbackStore._testDirectory = nil
        super.tearDown()
    }

    func testTrimDropsTrailingBlankLines() throws {
        let data = try XCTUnwrap(ScrollbackStore.trimmed("$ ls\nfile\n$ \n\u{1B}[0m   \n\n"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "$ ls\nfile\n$ ")
    }

    func testTrimReturnsNilForEmptyScreen() {
        XCTAssertNil(ScrollbackStore.trimmed("\n  \n\u{1B}[0m\n"))
    }

    func testTrimCapsAtLineBoundary() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(repeating: line, count: ScrollbackStore.maxBytes / 100 + 50)
        let data = try XCTUnwrap(ScrollbackStore.trimmed(text))
        XCTAssertLessThanOrEqual(data.count, ScrollbackStore.maxBytes)
        XCTAssertEqual(data.first, UInt8(ascii: "x"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix(String(repeating: "x", count: 99) + "\n"))
    }

    func testSaveScheduleTakeRoundTrip() throws {
        let saved = UUID()
        let restored = UUID()
        ScrollbackStore.save("hello\nworld", for: saved)
        let file = (dir as NSString).appendingPathComponent(saved.uuidString)
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        ScrollbackStore.schedule(savedID: saved, for: restored)
        let bytes = try XCTUnwrap(ScrollbackStore.take(for: restored))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello\r\nworld\u{1B}[0m\r\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertNil(ScrollbackStore.take(for: restored))
    }

    func testScheduleIgnoresMissingFile() {
        let restored = UUID()
        ScrollbackStore.schedule(savedID: UUID(), for: restored)
        XCTAssertNil(ScrollbackStore.take(for: restored))
    }

    func testPruneKeepsOnlyClaimedFiles() {
        let claimed = UUID()
        let orphan = UUID()
        ScrollbackStore.save("a", for: claimed)
        ScrollbackStore.save("b", for: orphan)
        ScrollbackStore.schedule(savedID: claimed, for: UUID())
        ScrollbackStore.pruneUnclaimed()
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        XCTAssertEqual(files, [claimed.uuidString])
    }

    func testSessionTabDecodesWithoutScrollbackID() throws {
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data("{}".utf8))
        XCTAssertNil(tab.scrollbackID)
    }
}
