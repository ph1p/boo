import Cocoa
import XCTest

@testable import Boo

@MainActor
final class BrowserContentViewTests: XCTestCase {

    func testSyncVisibleURLUpdatesCurrentURLAndAddressBar() {
        let view = BrowserContentView(url: ContentType.blankURL)
        let newURL = URL(string: "https://example.com/path")!

        view.syncVisibleURL(newURL)

        XCTAssertEqual(view.url, newURL)
        XCTAssertEqual(view.displayedURLString, newURL.absoluteString)
    }

    func testSyncVisibleURLFiresURLChangedCallback() {
        let view = BrowserContentView(url: ContentType.blankURL)
        let newURL = URL(string: "https://example.com/updated")!
        var receivedURL: URL?

        view.onURLChanged = { receivedURL = $0 }
        view.syncVisibleURL(newURL)

        XCTAssertEqual(receivedURL, newURL)
    }

    func testSyncVisibleURLCanRepeatSameURLWithoutBreakingState() {
        let view = BrowserContentView(url: ContentType.blankURL)
        let newURL = URL(string: "https://example.com/repeat")!
        var callbackCount = 0

        view.onURLChanged = { _ in callbackCount += 1 }
        view.syncVisibleURL(newURL)
        view.syncVisibleURL(newURL)

        XCTAssertEqual(view.url, newURL)
        XCTAssertEqual(view.displayedURLString, newURL.absoluteString)
        XCTAssertEqual(callbackCount, 2)
    }

    func testOpenURLInNewTabUsesCallbackWhenProvided() {
        let view = BrowserContentView(url: ContentType.blankURL)
        let newURL = URL(string: "https://example.com/new-tab")!
        var receivedURL: URL?

        view.onOpenURLInNewTab = { receivedURL = $0 }
        view.openURLInNewTab(newURL)

        XCTAssertEqual(receivedURL, newURL)
    }

    func testDownloadDestinationURLUsesSuggestedFilenameWhenAvailable() {
        let directory = URL(fileURLWithPath: "/tmp/download-tests", isDirectory: true)
        let result = BrowserContentView.downloadDestinationURL(
            in: directory,
            suggestedFilename: "asset.zip",
            fileExists: { _ in false }
        )

        XCTAssertEqual(result.lastPathComponent, "asset.zip")
    }

    func testDownloadDestinationURLAppendsNumberWhenFileExists() {
        let directory = URL(fileURLWithPath: "/tmp/download-tests", isDirectory: true)
        let existingNames = Set(["asset.zip", "asset 2.zip"])
        let result = BrowserContentView.downloadDestinationURL(
            in: directory,
            suggestedFilename: "asset.zip",
            fileExists: { existingNames.contains($0.lastPathComponent) }
        )

        XCTAssertEqual(result.lastPathComponent, "asset 3.zip")
    }
}
