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

    // MARK: - Address bar input

    func testResolveInputKeepsExplicitScheme() {
        XCTAssertEqual(
            BrowserContentView.resolveInput("http://example.com/a?b=1")?.absoluteString, "http://example.com/a?b=1")
        XCTAssertEqual(BrowserContentView.resolveInput("about:blank")?.absoluteString, "about:blank")
    }

    func testResolveInputUsesHTTPForLocalHosts() {
        XCTAssertEqual(BrowserContentView.resolveInput("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(
            BrowserContentView.resolveInput("localhost:5173/app")?.absoluteString, "http://localhost:5173/app")
        XCTAssertEqual(BrowserContentView.resolveInput("127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(BrowserContentView.resolveInput("printer.local")?.absoluteString, "http://printer.local")
    }

    func testResolveInputUsesHTTPSForDomains() {
        XCTAssertEqual(BrowserContentView.resolveInput("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(
            BrowserContentView.resolveInput("  github.com/ph1p/boo ")?.absoluteString, "https://github.com/ph1p/boo")
    }

    func testResolveInputTreatsPathsAsFiles() {
        let url = BrowserContentView.resolveInput("/tmp/index.html")
        XCTAssertEqual(url?.isFileURL, true)
        XCTAssertEqual(url?.path, "/tmp/index.html")
        XCTAssertEqual(BrowserContentView.resolveInput("~/x.html")?.path, NSHomeDirectory() + "/x.html")
    }

    func testResolveInputSearchesEverythingElse() {
        XCTAssertEqual(
            BrowserContentView.resolveInput("swift concurrency")?.absoluteString,
            "https://www.google.com/search?q=swift%20concurrency")
        XCTAssertEqual(
            BrowserContentView.resolveInput("a&b=c")?.absoluteString,
            "https://www.google.com/search?q=a%26b%3Dc")
        XCTAssertEqual(
            BrowserContentView.resolveInput("1.5")?.absoluteString, "https://www.google.com/search?q=1.5")
        XCTAssertNil(BrowserContentView.resolveInput("   "))
    }

    func testResolveInputPortShorthand() {
        XCTAssertEqual(BrowserContentView.resolveInput(":3000")?.absoluteString, "http://localhost:3000")
        // A bare number is a port only when a pane server listens on it.
        XCTAssertEqual(
            BrowserContentView.resolveInput("5173", knownPorts: [5173])?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(
            BrowserContentView.resolveInput("2024")?.absoluteString, "https://www.google.com/search?q=2024")
        XCTAssertEqual(
            BrowserContentView.resolveInput(":abc")?.absoluteString, "https://www.google.com/search?q=:abc")
    }

    func testServerItemsFilterByPortProcessAndPane() {
        let servers = [
            PaneServer(port: 3000, pid: 1, processName: "node", location: "web · shop"),
            PaneServer(port: 8000, pid: 2, processName: "python3", location: "api · shop")
        ]
        XCTAssertEqual(BrowserContentView.serverItems(servers, matching: "").count, 2)
        XCTAssertEqual(BrowserContentView.serverItems(servers, matching: ":30").map(\.url), [servers[0].url])
        XCTAssertEqual(BrowserContentView.serverItems(servers, matching: "python").map(\.url), [servers[1].url])
        XCTAssertEqual(BrowserContentView.serverItems(servers, matching: "api").map(\.url), [servers[1].url])
        XCTAssertTrue(BrowserContentView.serverItems(servers, matching: "github").isEmpty)
        XCTAssertEqual(BrowserContentView.serverItems(servers, matching: "").first?.subtitle, "node — web · shop")
    }

    func testServersButtonExistsInToolbar() {
        let view = BrowserContentView(url: ContentType.blankURL)
        XCTAssertNotNil(navButton(action: "showServersMenu:", in: view))
    }

    // MARK: - Zoom

    func testNextZoomStepsThroughLadderAndClamps() {
        XCTAssertEqual(BrowserContentView.nextZoom(from: 1, zoomIn: true), 1.1)
        XCTAssertEqual(BrowserContentView.nextZoom(from: 1, zoomIn: false), 0.9)
        XCTAssertEqual(BrowserContentView.nextZoom(from: 1.05, zoomIn: true), 1.1)
        XCTAssertEqual(BrowserContentView.nextZoom(from: 3, zoomIn: true), 3)
        XCTAssertEqual(BrowserContentView.nextZoom(from: 0.5, zoomIn: false), 0.5)
    }

    // MARK: - URL bar

    func testBlankURLLeavesAddressBarEmpty() {
        let view = BrowserContentView(url: ContentType.blankURL)
        XCTAssertEqual(view.displayedURLString, "")
    }

    func testRestoreStateUpdatesAddressBar() {
        let view = BrowserContentView(url: ContentType.blankURL)
        let url = URL(string: "https://example.com/restored")!
        view.restoreState(.browser(BrowserContentState(title: "R", url: url, canGoBack: false, canGoForward: false)))
        XCTAssertEqual(view.url, url)
        XCTAssertEqual(view.displayedURLString, url.absoluteString)
    }

    // MARK: - Error page

    func testCancelledAndDownloadFailuresAreSilent() {
        XCTAssertTrue(BrowserErrorView.isSilent(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(BrowserErrorView.isSilent(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(
            BrowserErrorView.isSilent(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
    }

    // MARK: - External browser button

    func testExternalBrowserButtonExistsInToolbar() {
        let view = BrowserContentView(url: ContentType.blankURL)
        XCTAssertNotNil(
            navButton(action: "openInExternalBrowserAction", in: view),
            "External browser button must exist in the toolbar")
    }

    /// The toolbar button wired to `action`, found by walking the subview tree.
    private func navButton(action: String, in view: NSView) -> NavHoverButton? {
        if let btn = view as? NavHoverButton, btn.action == NSSelectorFromString(action) { return btn }
        return view.subviews.lazy.compactMap { self.navButton(action: action, in: $0) }.first
    }

    // MARK: - performKeyEquivalent: non-edit keys pass through normally

    func testPerformKeyEquivalentDoesNotStealAddressBarPaste() {
        assertAddressBarEditShortcutPassesThrough(
            characters: "v",
            keyCode: 9,
            message: "BrowserContentView must not redirect address-bar paste to WKWebView")
    }

    func testPerformKeyEquivalentDoesNotStealAddressBarUndo() {
        assertAddressBarEditShortcutPassesThrough(
            characters: "z",
            keyCode: 6,
            message: "BrowserContentView must not redirect address-bar undo to WKWebView")
    }

    private func assertAddressBarEditShortcutPassesThrough(characters: String, keyCode: UInt16, message: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = BrowserContentView(url: ContentType.blankURL)
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        guard let addressBar = findSubview(of: SelectAllTextField.self, in: view) else {
            return XCTFail("Expected browser address bar")
        }
        window.makeFirstResponder(addressBar)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!

        XCTAssertFalse(view.performKeyEquivalent(with: event), message)
    }

    func testPerformKeyEquivalentNonEditKeyPassesThrough() {
        let view = BrowserContentView(url: ContentType.blankURL)
        // Cmd+N is not an edit key — should NOT be intercepted
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        // Without a window the guard `window?.firstResponder !== wv` is false,
        // so the switch default branch fires → super is called → returns false.
        let handled = view.performKeyEquivalent(with: event)
        XCTAssertFalse(handled, "Non-edit Cmd+key must not be consumed by BrowserContentView")
    }

    func testPerformKeyEquivalentNonCommandEventPassesThrough() {
        let view = BrowserContentView(url: ContentType.blankURL)
        // Plain key press without Cmd — guard fails immediately
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!
        let handled = view.performKeyEquivalent(with: event)
        XCTAssertFalse(handled, "Non-command key must not be intercepted")
    }

    private func findSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
