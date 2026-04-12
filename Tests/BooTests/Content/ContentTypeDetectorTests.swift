import XCTest

@testable import Boo

final class ContentTypeDetectorTests: XCTestCase {
    // MARK: - URL Detection

    func testDetectsHTTPURL() {
        XCTAssertEqual(ContentTypeDetector.detect(from: "https://example.com"), .browser)
        XCTAssertEqual(ContentTypeDetector.detect(from: "http://example.com"), .browser)
        XCTAssertEqual(ContentTypeDetector.detect(from: "https://example.com/path?query=1"), .browser)
    }

    func testDetectsHTTPSWithSpaces() {
        XCTAssertEqual(ContentTypeDetector.detect(from: "  https://example.com  "), .browser)
    }

    func testDoesNotDetectNonHTTPURL() {
        XCTAssertNil(ContentTypeDetector.detect(from: "file:///path/to/file"))
        XCTAssertNil(ContentTypeDetector.detect(from: "ftp://example.com"))
    }

    // MARK: - Image Detection

    func testDetectsImageFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic"]

        for ext in imageExtensions {
            let path = tempDir.appendingPathComponent("test.\(ext)").path
            FileManager.default.createFile(atPath: path, contents: nil)
            defer { try? FileManager.default.removeItem(atPath: path) }

            XCTAssertEqual(
                ContentTypeDetector.detect(from: path), .imageViewer,
                "Should detect .\(ext) as image"
            )
        }
    }

    // MARK: - Markdown Detection

    func testDetectsMarkdownFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let mdExtensions = ["md", "markdown", "mdown"]

        for ext in mdExtensions {
            let path = tempDir.appendingPathComponent("test.\(ext)").path
            FileManager.default.createFile(atPath: path, contents: nil)
            defer { try? FileManager.default.removeItem(atPath: path) }

            XCTAssertEqual(
                ContentTypeDetector.detect(from: path), .markdownPreview,
                "Should detect .\(ext) as markdown"
            )
        }
    }

    // MARK: - Non-Detection Cases

    func testDoesNotDetectNonExistentFile() {
        XCTAssertNil(ContentTypeDetector.detect(from: "/nonexistent/path/file.png"))
    }

    func testDoesNotDetectDirectories() {
        let tempDir = FileManager.default.temporaryDirectory.path
        XCTAssertNil(ContentTypeDetector.detect(from: tempDir))
    }

    func testDoesNotDetectGenericTextFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("test.txt").path
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Should not auto-detect editor (too generic)
        XCTAssertNil(ContentTypeDetector.detect(from: path))
    }

    func testDoesNotDetectEmptyString() {
        XCTAssertNil(ContentTypeDetector.detect(from: ""))
        XCTAssertNil(ContentTypeDetector.detect(from: "   "))
    }

    // MARK: - URL-like String Detection

    func testLooksLikeURL() {
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("https://example.com"))
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("http://example.com"))
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("www.example.com"))
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("localhost"))
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("example.com"))
        XCTAssertTrue(ContentTypeDetector.looksLikeURL("sub.example.com"))
    }

    func testDoesNotLookLikeURL() {
        XCTAssertFalse(ContentTypeDetector.looksLikeURL("just some text"))
        XCTAssertFalse(ContentTypeDetector.looksLikeURL("/path/to/file"))
        XCTAssertFalse(ContentTypeDetector.looksLikeURL("file.txt"))
    }

    // MARK: - URL Normalization

    func testNormalizeURL() {
        XCTAssertEqual(
            ContentTypeDetector.normalizeURL("https://example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            ContentTypeDetector.normalizeURL("example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            ContentTypeDetector.normalizeURL("www.example.com")?.absoluteString,
            "https://www.example.com"
        )
        XCTAssertNil(ContentTypeDetector.normalizeURL("not a url"))
    }
}
