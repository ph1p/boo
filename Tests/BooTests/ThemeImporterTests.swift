import XCTest

@testable import Boo

final class ThemeImporterTests: XCTestCase {

    private func component(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
        ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": "sRGB"]
    }

    func testParsesITermPlist() throws {
        var plist: [String: Any] = [
            "Background Color": component(0, 0, 0),
            "Foreground Color": component(1, 1, 1),
            "Cursor Color": component(1, 0, 0)
        ]
        for i in 0..<16 { plist["Ansi \(i) Color"] = component(Double(i) / 15, 0, 0) }
        let theme = try ThemeImporter.parseITerm(plist, name: "Mono")
        XCTAssertEqual(theme.name, "Mono")
        XCTAssertEqual(theme.background, TerminalColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.foreground, TerminalColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(theme.cursor, TerminalColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(theme.ansiColors.count, 16)
        XCTAssertEqual(theme.ansiColors[15], TerminalColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(theme.accentHex, theme.ansiColors[4].hexString)
    }

    func testITermWithoutBackgroundFails() {
        let plist: [String: Any] = ["Foreground Color": component(1, 1, 1)]
        XCTAssertThrowsError(try ThemeImporter.parseITerm(plist, name: "x"))
    }

    func testParsesGhosttyTheme() throws {
        let text = """
            # comment
            palette = 0=#1d1f21
            palette = 4 = #81a2be
            background = #1d1f21
            foreground = #c5c8c6
            cursor-color = #c5c8c6
            selection-background = #373b41
            """
        let theme = try ThemeImporter.parseGhostty(text, name: "Tomorrow")
        XCTAssertEqual(theme.background, TerminalColor(hex: "#1d1f21"))
        XCTAssertEqual(theme.foreground, TerminalColor(hex: "#c5c8c6"))
        XCTAssertEqual(theme.ansiColors[0], TerminalColor(hex: "#1d1f21"))
        XCTAssertEqual(theme.ansiColors[4], TerminalColor(hex: "#81a2be"))
        XCTAssertEqual(theme.ansiColors.count, 16)
        XCTAssertEqual(theme.selectionHex, "#373B41")
    }

    func testGhosttyWithoutKnownKeysIsRejected() {
        XCTAssertThrowsError(try ThemeImporter.parseGhostty("hello world\nfoo = bar", name: "x"))
    }

    func testImportFromFileUsesFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Night Owl")
        try "background = #011627\nforeground = #d6deeb\n".write(to: url, atomically: true, encoding: .utf8)
        let theme = try ThemeImporter.importTheme(at: url)
        XCTAssertEqual(theme.name, "Night Owl")
        XCTAssertEqual(theme.background, TerminalColor(hex: "#011627"))
    }
}
