import XCTest

@testable import Exterm

final class FileIconTests: XCTestCase {

    func testSwiftIcon() {
        XCTAssertEqual(fileIcon(for: "main.swift"), "swift")
    }

    func testJavaScriptIcon() {
        XCTAssertEqual(fileIcon(for: "app.js"), "doc.text")
        XCTAssertEqual(fileIcon(for: "component.tsx"), "doc.text")
    }

    func testJsonIcon() {
        XCTAssertEqual(fileIcon(for: "package.json"), "curlybraces")
    }

    func testMarkdownIcon() {
        XCTAssertEqual(fileIcon(for: "README.md"), "doc.plaintext")
    }

    func testImageIcon() {
        XCTAssertEqual(fileIcon(for: "photo.png"), "photo")
        XCTAssertEqual(fileIcon(for: "logo.svg"), "photo")
    }

    func testShellIcon() {
        XCTAssertEqual(fileIcon(for: "build.sh"), "terminal")
        XCTAssertEqual(fileIcon(for: "setup.zsh"), "terminal")
    }

    func testConfigIcon() {
        XCTAssertEqual(fileIcon(for: "config.yml"), "gearshape")
        XCTAssertEqual(fileIcon(for: "settings.toml"), "gearshape")
    }

    func testCCodeIcon() {
        XCTAssertEqual(fileIcon(for: "main.c"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(fileIcon(for: "header.h"), "chevron.left.forwardslash.chevron.right")
    }

    func testUnknownIcon() {
        XCTAssertEqual(fileIcon(for: "data.xyz"), "doc")
        XCTAssertEqual(fileIcon(for: "noext"), "doc")
    }

    func testShellEscape() {
        XCTAssertEqual(shellEscape("/simple/path"), "'/simple/path'")
        XCTAssertEqual(shellEscape("/path with spaces"), "'/path with spaces'")
        XCTAssertEqual(shellEscape("/it's a test"), "'/it'\\''s a test'")
        XCTAssertEqual(shellEscape("hello$world"), "'hello$world'")
    }
}
