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

    // MARK: - Well-known filenames

    @MainActor
    func testLicenseAndBuildFilesAreEditorFiles() {
        for name in ["LICENSE", "LICENSE.txt", "LICENSE-MIT", "COPYING", "Gemfile", "Justfile", "Procfile"] {
            XCTAssertTrue(ContentType.isEditorFilePattern(filename: name), name)
        }
    }

    // MARK: - Content sniffing

    private func temporaryFile(_ name: String, _ bytes: [UInt8]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    @MainActor
    func testExtensionlessScriptOpensInEditor() throws {
        let path = try temporaryFile("deploy", Array("#!/bin/bash\necho hi\n".utf8))
        XCTAssertTrue(ContentType.opensInEditor(path: path))
    }

    @MainActor
    func testExtensionlessBinaryDoesNotOpenInEditor() throws {
        let path = try temporaryFile("tool", [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
        XCTAssertFalse(ContentType.opensInEditor(path: path))
    }

    @MainActor
    func testUnknownExtensionWithTextOpensInEditor() throws {
        let path = try temporaryFile("settings.myconf", Array("key = value\n".utf8))
        XCTAssertTrue(ContentType.opensInEditor(path: path))
    }

    @MainActor
    func testKnownNonTextExtensionIsNotSniffed() throws {
        // Text bytes, but the system knows .mp4 as a movie.
        let path = try temporaryFile("clip.mp4", Array("not really a movie".utf8))
        XCTAssertFalse(ContentType.opensInEditor(path: path))
    }

    @MainActor
    func testSvgStaysOutOfEditor() throws {
        let path = try temporaryFile("icon.svg", Array("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))
        XCTAssertFalse(ContentType.opensInEditor(path: path))
    }

    @MainActor
    func testDirectoryAndMissingFileAreNotText() throws {
        let path = try temporaryFile("x", [])
        XCTAssertFalse(ContentType.isTextFile(atPath: (path as NSString).deletingLastPathComponent))
        XCTAssertFalse(ContentType.isTextFile(atPath: path + "-missing"))
        XCTAssertTrue(ContentType.isTextFile(atPath: path), "an empty file is text")
    }

    func testLooksLikeText() {
        XCTAssertTrue(ContentType.looksLikeText(Data("plain\ttext\r\n\u{1B}[31mred\u{1B}[0m".utf8)))
        XCTAssertTrue(ContentType.looksLikeText(Data("Grüße, café".utf8)))
        XCTAssertTrue(ContentType.looksLikeText(Data([0xFF, 0xFE, 0x41, 0x00])), "UTF-16 with BOM")
        XCTAssertFalse(ContentType.looksLikeText(Data([0x41, 0x00, 0x42])), "NUL byte")
        XCTAssertFalse(ContentType.looksLikeText(Data([0x01, 0x02, 0x03, 0x41])), "mostly control bytes")
    }
}
