import XCTest

@testable import Boo

/// Tests for ContentType.isEditorFilePattern — routing text files to the built-in editor tab.
final class ContentTypeEditorExtensionTests: XCTestCase {
    // MARK: - Default extensions

    @MainActor
    func testSwiftFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "File.swift"))
    }

    @MainActor
    func testJavaScriptFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "app.js"))
    }

    @MainActor
    func testTypeScriptFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "index.ts"))
    }

    @MainActor
    func testPythonFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "script.py"))
    }

    @MainActor
    func testTxtFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "notes.txt"))
    }

    @MainActor
    func testJsonFileIsEditorExtension() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "config.json"))
    }

    // MARK: - Non-editor extensions

    @MainActor
    func testPngFileIsNotEditorExtension() {
        // Images are handled separately by imageViewer
        XCTAssertFalse(ContentType.isEditorFilePattern(filename: "image.png"))
    }

    @MainActor
    func testMp4FileIsNotEditorExtension() {
        XCTAssertFalse(ContentType.isEditorFilePattern(filename: "video.mp4"))
    }

    @MainActor
    func testNoExtensionIsNotEditorExtension() {
        XCTAssertFalse(ContentType.isEditorFilePattern(filename: "binary"))
    }

    // MARK: - Case insensitivity

    @MainActor
    func testEditorExtensionIsCaseInsensitive() {
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "File.SWIFT"))
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "File.Swift"))
        XCTAssertTrue(ContentType.isEditorFilePattern(filename: "App.JS"))
    }
}
