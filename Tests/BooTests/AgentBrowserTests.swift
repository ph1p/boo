import XCTest

@testable import Boo

@MainActor
final class AgentBrowserTests: XCTestCase {
    func testURLGetsSchemeLikeTheAddressBar() throws {
        XCTAssertEqual(try AgentBrowser.url("localhost:3000/x").absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(try AgentBrowser.url("127.0.0.1:8080").absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(try AgentBrowser.url("example.com").absoluteString, "https://example.com")
        XCTAssertEqual(try AgentBrowser.url("http://a.test/").absoluteString, "http://a.test/")
        XCTAssertEqual(try AgentBrowser.url("about:blank").absoluteString, "about:blank")
        XCTAssertTrue(try AgentBrowser.url("/tmp/a.html").isFileURL)
        XCTAssertEqual(try AgentBrowser.url(":3000").absoluteString, "http://localhost:3000")
        XCTAssertThrowsError(try AgentBrowser.url("not a url"), "the address bar would search for it")
    }

    func testApprovalCardNamesBrowserActions() {
        XCTAssertEqual(ApprovalCenter.action(cmd: "browser_eval", json: [:]), "Run JavaScript in browser tab")
    }
}
