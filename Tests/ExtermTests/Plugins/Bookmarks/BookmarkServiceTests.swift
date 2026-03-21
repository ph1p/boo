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
        service.add(name: "B", path: "/tmp")  // Same path
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

    // MARK: - Namespace Tests

    func testAddBookmarkWithNamespace() {
        let service = BookmarkService.shared
        service.add(name: "Remote Dir", path: "/home/user/projects", namespace: "ssh:host1")
        XCTAssertEqual(service.bookmarks.count, 1)
        XCTAssertEqual(service.bookmarks[0].namespace, "ssh:host1")
    }

    func testDefaultNamespaceIsLocal() {
        let service = BookmarkService.shared
        service.add(name: "Local", path: "/tmp")
        XCTAssertEqual(service.bookmarks[0].namespace, "local")
    }

    func testFilterBookmarksByNamespace() {
        let service = BookmarkService.shared
        service.add(name: "Local A", path: "/a", namespace: "local")
        service.add(name: "Remote B", path: "/b", namespace: "ssh:host1")
        service.add(name: "Remote C", path: "/c", namespace: "ssh:host1")
        service.add(name: "Docker D", path: "/d", namespace: "docker:web")

        let local = service.bookmarks(for: "local")
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local[0].name, "Local A")

        let sshBookmarks = service.bookmarks(for: "ssh:host1")
        XCTAssertEqual(sshBookmarks.count, 2)

        let dockerBookmarks = service.bookmarks(for: "docker:web")
        XCTAssertEqual(dockerBookmarks.count, 1)
    }

    func testNoDuplicatesWithinSameNamespace() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/tmp", namespace: "ssh:host1")
        service.add(name: "B", path: "/tmp", namespace: "ssh:host1")
        XCTAssertEqual(service.bookmarks.count, 1)
    }

    func testSamePathDifferentNamespacesAllowed() {
        let service = BookmarkService.shared
        service.add(name: "Local", path: "/tmp", namespace: "local")
        service.add(name: "Remote", path: "/tmp", namespace: "ssh:host1")
        XCTAssertEqual(service.bookmarks.count, 2)
    }

    func testContainsRespectsNamespace() {
        let service = BookmarkService.shared
        service.add(name: "A", path: "/tmp", namespace: "ssh:host1")
        XCTAssertTrue(service.contains(path: "/tmp", namespace: "ssh:host1"))
        XCTAssertFalse(service.contains(path: "/tmp", namespace: "local"))
    }

    func testBackwardCompatibleDecoding() {
        // Simulate a bookmark encoded without namespace field
        let json = """
            {"id": "12345678-1234-1234-1234-123456789012", "name": "Old", "path": "/old", "icon": "folder"}
            """
        let data = json.data(using: .utf8)!
        let bookmark = try? JSONDecoder().decode(BookmarkService.Bookmark.self, from: data)
        XCTAssertNotNil(bookmark)
        XCTAssertEqual(bookmark?.namespace, "local", "Missing namespace should default to 'local'")
    }
}
