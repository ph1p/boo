import XCTest

@testable import Boo

/// Tests for BrowserHistory filtering — verifies the autocomplete prefix logic works correctly.
@MainActor
final class BrowserHistoryAutocompleteTests: XCTestCase {

    override func setUp() async throws {
        // Reset singleton state before each test
        BrowserHistory.shared.clear()
        // Also enable history so record() doesn't skip entries
        AppSettings.shared.browserHistoryEnabled = true
    }

    override func tearDown() async throws {
        BrowserHistory.shared.clear()
    }

    // MARK: - Entry deduplication

    func testConsecutiveDuplicatesAreSkipped() {
        let url = URL(string: "https://example.com")!
        BrowserHistory.shared.record(title: "Example", url: url)
        BrowserHistory.shared.record(title: "Example", url: url)
        XCTAssertEqual(BrowserHistory.shared.entries.count, 1)
    }

    func testDifferentURLsAreNotDeduplicated() {
        BrowserHistory.shared.record(title: "A", url: URL(string: "https://a.com")!)
        BrowserHistory.shared.record(title: "B", url: URL(string: "https://b.com")!)
        XCTAssertEqual(BrowserHistory.shared.entries.count, 2)
    }

    func testNonHTTPUrlsAreSkipped() {
        BrowserHistory.shared.record(title: "FTP", url: URL(string: "ftp://example.com")!)
        XCTAssertEqual(BrowserHistory.shared.entries.count, 0)
    }

    func testBlankURLIsSkipped() {
        BrowserHistory.shared.record(title: "Blank", url: URL(string: "about:blank")!)
        XCTAssertEqual(BrowserHistory.shared.entries.count, 0)
    }

    // MARK: - Autocomplete filtering (mimics BrowserContentView logic)

    func testPrefixFilterMatchesURL() {
        BrowserHistory.shared.record(title: "GitHub", url: URL(string: "https://github.com")!)
        BrowserHistory.shared.record(title: "Google", url: URL(string: "https://google.com")!)
        BrowserHistory.shared.record(title: "Apple", url: URL(string: "https://apple.com")!)

        let query = "github"
        let matches = BrowserHistory.shared.entries.filter {
            $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "GitHub")
    }

    func testPrefixFilterMatchesTitle() {
        BrowserHistory.shared.record(title: "My Favorite Site", url: URL(string: "https://example.com/fav")!)
        BrowserHistory.shared.record(title: "Other Site", url: URL(string: "https://other.com")!)

        let query = "favorite"
        let matches = BrowserHistory.shared.entries.filter {
            $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "My Favorite Site")
    }

    func testFilterIsCaseInsensitive() {
        BrowserHistory.shared.record(title: "GitHub", url: URL(string: "https://github.com")!)
        let matches = BrowserHistory.shared.entries.filter {
            $0.url.absoluteString.localizedCaseInsensitiveContains("GITHUB")
                || $0.title.localizedCaseInsensitiveContains("GITHUB")
        }
        XCTAssertEqual(matches.count, 1)
    }

    func testFilterReturnsEmptyForNoMatch() {
        BrowserHistory.shared.record(title: "GitHub", url: URL(string: "https://github.com")!)
        let matches = BrowserHistory.shared.entries.filter {
            $0.url.absoluteString.localizedCaseInsensitiveContains("zzz-no-match")
                || $0.title.localizedCaseInsensitiveContains("zzz-no-match")
        }
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Clear

    func testClearRemovesAllEntries() {
        BrowserHistory.shared.record(title: "A", url: URL(string: "https://a.com")!)
        BrowserHistory.shared.record(title: "B", url: URL(string: "https://b.com")!)
        BrowserHistory.shared.clear()
        XCTAssertTrue(BrowserHistory.shared.entries.isEmpty)
    }

    func testRemoveSingleEntry() {
        BrowserHistory.shared.record(title: "A", url: URL(string: "https://a.com")!)
        guard let id = BrowserHistory.shared.entries.first?.id else {
            XCTFail("No entry recorded")
            return
        }
        BrowserHistory.shared.remove(id: id)
        XCTAssertTrue(BrowserHistory.shared.entries.isEmpty)
    }
}
