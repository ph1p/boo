import XCTest
@testable import Exterm

final class BookmarkServiceTests: XCTestCase {

    override func setUp() {
        // Clear bookmarks for clean test state
        let service = BookmarkService.shared
        while !service.bookmarks.isEmpty {
            service.remove(at: 0)
        }
    }

    func testAddBookmark() {
        let service = BookmarkService.shared
        service.add(name: "Home", path: "/Users/test")
        XCTAssertEqual(service.bookmarks.count, 1)
        XCTAssertEqual(service.bookmarks[0].name, "Home")
        XCTAssertEqual(service.bookmarks[0].path, "/Users/test")
    }

    func testAddCurrentDirectory() {
        let service = BookmarkService.shared
        service.addCurrentDirectory("/Users/test/Documents")
        XCTAssertEqual(service.bookmarks.count, 1)
        XCTAssertEqual(service.bookmarks[0].name, "Documents")
    }

    func testNoDuplicates() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/tmp")
        service.add(name: "B", path: "/tmp") // Same path
        XCTAssertEqual(service.bookmarks.count, 1)
    }

    func testRemoveBookmark() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/a")
        service.add(name: "B", path: "/b")
        service.remove(at: 0)
        XCTAssertEqual(service.bookmarks.count, 1)
        XCTAssertEqual(service.bookmarks[0].path, "/b")
    }

    func testRemoveByID() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/a")
        let id = service.bookmarks[0].id
        service.remove(id: id)
        XCTAssertTrue(service.bookmarks.isEmpty)
    }

    func testRename() {
        let service = BookmarkService.shared
        service.add(name: "Old", path: "/tmp")
        let id = service.bookmarks[0].id
        service.rename(id: id, to: "New")
        XCTAssertEqual(service.bookmarks[0].name, "New")
    }

    func testContains() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/tmp")
        XCTAssertTrue(service.contains(path: "/tmp"))
        XCTAssertFalse(service.contains(path: "/home"))
    }
}
