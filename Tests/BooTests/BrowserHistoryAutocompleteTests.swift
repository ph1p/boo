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
