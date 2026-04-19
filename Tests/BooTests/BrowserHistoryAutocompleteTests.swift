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

    func testConsecutiveDuplicateRefreshesMostRecentTitle() {
        let url = URL(string: "https://example.com")!
        BrowserHistory.shared.record(title: "Example Old", url: url)
        BrowserHistory.shared.record(title: "Example New", url: url)

        XCTAssertEqual(BrowserHistory.shared.entries.count, 1)
        XCTAssertEqual(BrowserHistory.shared.entries.first?.title, "Example New")
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

    // MARK: - Autocomplete URL deduplication (mirrors BrowserContentView.showAutocomplete)

    /// Helper that replicates the dedup logic from showAutocomplete.
    private func deduped(from entries: [BrowserHistoryEntry], query: String) -> [BrowserHistoryEntry] {
        let filtered: [BrowserHistoryEntry]
        if query.isEmpty {
            filtered = Array(entries.prefix(8))
        } else {
            filtered = entries.filter {
                $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
        }
        var seen = Set<URL>()
        return filtered.filter { seen.insert($0.url).inserted }
    }

    func testAutocompleteDeduplicatesSameURLWithDifferentTitles() {
        let url = URL(string: "https://example.com")!
        // Same URL recorded twice (e.g. title changed between visits)
        BrowserHistory.shared.record(title: "Example Old", url: url)
        // Insert a different URL in between so BrowserHistory doesn't skip the second record
        BrowserHistory.shared.record(title: "Other", url: URL(string: "https://other.com")!)
        BrowserHistory.shared.record(title: "Example New", url: url)

        let result = deduped(from: BrowserHistory.shared.entries, query: "example.com")
        let urls = result.map(\.url)
        XCTAssertEqual(urls.filter { $0 == url }.count, 1, "same URL should appear only once")
    }

    func testAutocompleteDeduplicatesToMostRecentEntry() {
        let url = URL(string: "https://example.com")!
        BrowserHistory.shared.record(title: "Example Old", url: url)
        BrowserHistory.shared.record(title: "Spacer", url: URL(string: "https://spacer.com")!)
        BrowserHistory.shared.record(title: "Example New", url: url)

        // entries are newest-first, so deduped should keep the first occurrence = newest
        let result = deduped(from: BrowserHistory.shared.entries, query: "example.com")
        XCTAssertEqual(result.first(where: { $0.url == url })?.title, "Example New")
    }

    func testAutocompleteNoDuplicatesWhenAllUnique() {
        let urls = ["https://a.com", "https://b.com", "https://c.com"].map { URL(string: $0)! }
        for (i, url) in urls.enumerated() {
            BrowserHistory.shared.record(title: "Site \(i)", url: url)
        }
        let result = deduped(from: BrowserHistory.shared.entries, query: "")
        XCTAssertEqual(result.count, urls.count)
    }

    func testAutocompleteLimitedToEightResults() {
        for i in 0..<12 {
            BrowserHistory.shared.record(title: "Site \(i)", url: URL(string: "https://site\(i).com")!)
        }
        let result = deduped(from: BrowserHistory.shared.entries, query: "")
        XCTAssertLessThanOrEqual(result.count, 8)
    }

    // MARK: - Autocomplete panel sizing

    func testAutocompletePanelHeightIsZeroForNoItems() {
        XCTAssertEqual(URLAutocompletePanel.panelHeight(forItemCount: 0), 0)
    }

    func testAutocompletePanelHeightKeepsSingleItemAboveOneRow() {
        let height = URLAutocompletePanel.panelHeight(forItemCount: 1)
        XCTAssertEqual(height, URLAutocompletePanel.defaultRowHeight * URLAutocompletePanel.minimumVisibleRows)
        XCTAssertGreaterThan(height, URLAutocompletePanel.defaultRowHeight)
    }

    func testAutocompletePanelHeightUsesContentHeightForTwoItems() {
        XCTAssertEqual(
            URLAutocompletePanel.panelHeight(forItemCount: 2),
            URLAutocompletePanel.defaultRowHeight * 2
        )
    }

    func testAutocompletePanelHeightCapsAtMaximumVisibleRows() {
        XCTAssertEqual(
            URLAutocompletePanel.panelHeight(forItemCount: 20),
            URLAutocompletePanel.defaultRowHeight * URLAutocompletePanel.maxVisibleRows
        )
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
