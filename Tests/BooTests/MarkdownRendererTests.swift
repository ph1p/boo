import XCTest

@testable import Boo

final class MarkdownRendererTests: XCTestCase {
    func testRenderHTMLUsesIronmarkRenderer() {
        let html = MarkdownRenderer.renderHTML(from: "# Hello\n\n**World**")

        XCTAssertTrue(html.contains("<h1>Hello</h1>"))
        XCTAssertTrue(html.contains("<strong>World</strong>"))
    }
}
