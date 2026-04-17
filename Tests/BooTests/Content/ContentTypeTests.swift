import XCTest

@testable import Boo

final class ContentTypeTests: XCTestCase {
    func testAllCases() {
        let allCases = ContentType.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.terminal))
        XCTAssertTrue(allCases.contains(.browser))
        XCTAssertTrue(allCases.contains(.editor))
        XCTAssertTrue(allCases.contains(.imageViewer))
        XCTAssertTrue(allCases.contains(.markdownPreview))
        XCTAssertTrue(allCases.contains(.pluginView))
    }

    func testSymbolNames() {
        XCTAssertEqual(ContentType.terminal.symbolName, "terminal")
        XCTAssertEqual(ContentType.browser.symbolName, "globe")
        XCTAssertEqual(ContentType.editor.symbolName, "doc.text")
        XCTAssertEqual(ContentType.imageViewer.symbolName, "photo")
        XCTAssertEqual(ContentType.markdownPreview.symbolName, "doc.richtext")
    }

    func testDisplayNames() {
        XCTAssertEqual(ContentType.terminal.displayName, "Terminal")
        XCTAssertEqual(ContentType.browser.displayName, "Browser")
        XCTAssertEqual(ContentType.editor.displayName, "Editor")
        XCTAssertEqual(ContentType.imageViewer.displayName, "Image")
        XCTAssertEqual(ContentType.markdownPreview.displayName, "Markdown")
    }

    func testSupportsPlugins() {
        XCTAssertTrue(ContentType.terminal.supportsPlugins)
        XCTAssertFalse(ContentType.browser.supportsPlugins)
        XCTAssertFalse(ContentType.editor.supportsPlugins)
        XCTAssertFalse(ContentType.imageViewer.supportsPlugins)
        XCTAssertFalse(ContentType.markdownPreview.supportsPlugins)
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for type in ContentType.allCases {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(ContentType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    func testDefaultTabTitles() {
        XCTAssertEqual(ContentType.terminal.defaultTabTitle, "shell")
        XCTAssertEqual(ContentType.browser.defaultTabTitle, "New Tab")
        XCTAssertEqual(ContentType.editor.defaultTabTitle, "Untitled")
        XCTAssertEqual(ContentType.imageViewer.defaultTabTitle, "Image")
        XCTAssertEqual(ContentType.markdownPreview.defaultTabTitle, "Markdown")
    }

    func testBlankURL() {
        XCTAssertEqual(ContentType.blankURL.absoluteString, "about:blank")
    }

    // MARK: - creatableTypes

    func testCreatableTypesIncludesTerminalAndBrowser() {
        let types = ContentType.creatableTypes
        XCTAssertTrue(types.contains(.terminal))
        XCTAssertTrue(types.contains(.browser))
    }

    func testCreatableTypesExcludesFileViewers() {
        let types = ContentType.creatableTypes
        XCTAssertFalse(types.contains(.editor))
        XCTAssertFalse(types.contains(.imageViewer))
        XCTAssertFalse(types.contains(.markdownPreview))
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
