import XCTest

@testable import Boo

/// Tests for ContentType.isEditorExtension — routing text files to the built-in editor tab.
final class ContentTypeEditorExtensionTests: XCTestCase {
    // MARK: - Default extensions

    @MainActor
    func testSwiftFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/File.swift"))
    }

    @MainActor
    func testJavaScriptFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/app.js"))
    }

    @MainActor
    func testTypeScriptFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/index.ts"))
    }

    @MainActor
    func testPythonFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/script.py"))
    }

    @MainActor
    func testTxtFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/notes.txt"))
    }

    @MainActor
    func testJsonFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/config.json"))
    }

    // MARK: - Non-editor extensions

    @MainActor
    func testPngFileIsNotEditorExtension() {
        // Images are handled separately by imageViewer
        XCTAssertFalse(ContentType.isEditorExtension("/path/to/image.png"))
    }

    @MainActor
    func testMp4FileIsNotEditorExtension() {
        XCTAssertFalse(ContentType.isEditorExtension("/path/to/video.mp4"))
    }

    @MainActor
    func testNoExtensionIsNotEditorExtension() {
        XCTAssertFalse(ContentType.isEditorExtension("/path/to/binary"))
    }

    // MARK: - Case insensitivity

    @MainActor
    func testEditorExtensionIsCaseInsensitive() {
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/File.SWIFT"))
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/File.Swift"))
        XCTAssertTrue(ContentType.isEditorExtension("/path/to/App.JS"))
    }
}
