import XCTest

@testable import Boo

final class ContentTypeTests: XCTestCase {
    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for type in ContentType.allCases {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(ContentType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - forFile

    func testForFileMarkdown() {
        XCTAssertEqual(ContentType.forFile("/path/to/README.md"), .markdownPreview)
        XCTAssertEqual(ContentType.forFile("/path/to/doc.markdown"), .markdownPreview)
        XCTAssertEqual(ContentType.forFile("/path/to/notes.mdown"), .markdownPreview)
        XCTAssertEqual(ContentType.forFile("/path/to/file.mkd"), .markdownPreview)
    }

    func testForFileMarkdownCaseInsensitive() {
        XCTAssertEqual(ContentType.forFile("/path/to/FILE.MD"), .markdownPreview)
        XCTAssertEqual(ContentType.forFile("/path/to/README.Markdown"), .markdownPreview)
    }

    func testForFileImages() {
        XCTAssertEqual(ContentType.forFile("/path/to/image.png"), .imageViewer)
        XCTAssertEqual(ContentType.forFile("/path/to/photo.jpg"), .imageViewer)
        XCTAssertEqual(ContentType.forFile("/path/to/photo.jpeg"), .imageViewer)
        XCTAssertEqual(ContentType.forFile("/path/to/anim.gif"), .imageViewer)
        XCTAssertEqual(ContentType.forFile("/path/to/image.webp"), .imageViewer)
        XCTAssertNil(ContentType.forFile("/path/to/icon.svg"))
        XCTAssertEqual(ContentType.forFile("/path/to/photo.heic"), .imageViewer)
    }

    func testForFileUnknownReturnsNil() {
        XCTAssertNil(ContentType.forFile("/path/to/script.swift"))
        XCTAssertNil(ContentType.forFile("/path/to/data.json"))
        XCTAssertNil(ContentType.forFile("/path/to/config.yaml"))
        XCTAssertNil(ContentType.forFile("/path/to/binary"))
    }

    // MARK: - isMarkdown

    func testIsMarkdown() {
        XCTAssertTrue(ContentType.isMarkdown("/path/to/README.md"))
        XCTAssertTrue(ContentType.isMarkdown("/path/to/doc.markdown"))
        XCTAssertFalse(ContentType.isMarkdown("/path/to/script.swift"))
        XCTAssertFalse(ContentType.isMarkdown("/path/to/image.png"))
    }
}
