import WebKit
import XCTest

@testable import Boo

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testSchemeURLRoundTripsPathWithSpaces() throws {
        let path = "/Users/me/my docs/read me.md"
        let url = try XCTUnwrap(MarkdownAssetSchemeHandler.url(forPath: path))
        XCTAssertEqual(url.scheme, MarkdownAssetSchemeHandler.scheme)
        XCTAssertEqual(MarkdownAssetSchemeHandler.filePath(for: url), path)
    }

    func testRelativeImageResolvesAgainstSchemeBase() throws {
        let base = try XCTUnwrap(MarkdownAssetSchemeHandler.url(forPath: "/repo/docs/README.md"))
        let image = try XCTUnwrap(URL(string: "../img/a%20b.png", relativeTo: base))
        XCTAssertEqual(MarkdownAssetSchemeHandler.filePath(for: image), "/repo/img/a b.png")
    }

    func testFilePathRejectsForeignHostsAndSchemes() throws {
        XCTAssertNil(MarkdownAssetSchemeHandler.filePath(for: try XCTUnwrap(URL(string: "boo-md://evil/etc/passwd"))))
        XCTAssertNil(MarkdownAssetSchemeHandler.filePath(for: try XCTUnwrap(URL(string: "https://example.com/a.png"))))
        XCTAssertEqual(
            MarkdownAssetSchemeHandler.filePath(for: URL(fileURLWithPath: "/tmp/x.png")), "/tmp/x.png")
    }

    func testOnlyImagesAreServed() {
        XCTAssertTrue(MarkdownAssetSchemeHandler.servedExtensions.contains("png"))
        XCTAssertTrue(MarkdownAssetSchemeHandler.servedExtensions.contains("svg"))
        XCTAssertFalse(MarkdownAssetSchemeHandler.servedExtensions.contains("md"))
        XCTAssertFalse(MarkdownAssetSchemeHandler.servedExtensions.contains("txt"))
    }

    func testDocumentLocksScriptsToItsNonce() throws {
        let html = MarkdownPreviewPage.document(
            body: "<h1>Hi</h1><script>alert(1)</script>",
            colors: .init(background: "#000000", foreground: "#ffffff", muted: "#888888"),
            options: .init())
        let range = try XCTUnwrap(html.range(of: #"script-src 'nonce-([0-9A-F]+)'"#, options: .regularExpression))
        let nonce = String(html[range].dropFirst("script-src 'nonce-".count).dropLast())
        XCTAssertTrue(html.contains("<script nonce=\"\(nonce)\">"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("<article id=\"boo-content\">"))
    }
}

/// Loads the real page in WebKit: local images come through the scheme
/// handler, raw `<script>` in the markdown is blocked, find highlights hits.
@MainActor
final class MarkdownPreviewWebKitTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    }

    private func evaluate(_ webView: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) -> Any? {
        let done = expectation(description: script)
        var value: Any?
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            value = try? result.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return value
    }

    func testPageLoadsLocalImageBlocksInjectedScriptAndFinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boo-md-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("sub dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try png.write(to: dir.appendingPathComponent("dot one.png"))
        let mdPath = dir.appendingPathComponent("README.md").path

        let body = MarkdownRenderer.renderHTML(
            from: "# Title\n\n![dot](dot%20one.png)\n\nfoo bar foo\n\n<script>window.injected = 1</script>\n")
        let html = MarkdownPreviewPage.document(
            body: body, colors: .init(background: "#000000", foreground: "#ffffff", muted: "#888888"),
            options: .init())

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MarkdownAssetSchemeHandler(), forURLScheme: MarkdownAssetSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        let waiter = LoadWaiter(expectation(description: "loaded"))
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: MarkdownAssetSchemeHandler.url(forPath: mdPath))
        wait(for: [waiter.done], timeout: 10)

        let width = evaluate(
            webView,
            """
            const img = document.querySelector('#boo-content img');
            if (!img.complete) await new Promise(r => { img.onload = r; img.onerror = r; });
            return img.naturalWidth;
            """)
        XCTAssertEqual((width as? NSNumber)?.intValue, 1, "local image should load through boo-md:")

        XCTAssertEqual(
            evaluate(webView, "return typeof window.injected") as? String, "undefined",
            "inline script in markdown must be blocked by CSP")
        XCTAssertEqual(evaluate(webView, "return document.querySelector('h1').id") as? String, "title")

        let found = evaluate(webView, "return booFind(needle)", ["needle": "foo"]) as? [NSNumber]
        XCTAssertEqual(found?.map(\.intValue), [0, 2])
    }
}
