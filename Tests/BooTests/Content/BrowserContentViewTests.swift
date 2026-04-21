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

    // MARK: - External browser button

    func testExternalBrowserButtonExistsInToolbar() {
        let view = BrowserContentView(url: ContentType.blankURL)

        // Walk subview tree to find a button whose action is openInExternalBrowserAction
        let sel = NSSelectorFromString("openInExternalBrowserAction")
        func findButton(in v: NSView) -> NavHoverButton? {
            if let btn = v as? NavHoverButton, btn.action == sel { return btn }
            for sub in v.subviews {
                if let found = findButton(in: sub) { return found }
            }
            return nil
        }
        XCTAssertNotNil(findButton(in: view), "External browser button must exist in the toolbar")
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
