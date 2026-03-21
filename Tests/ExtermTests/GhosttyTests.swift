import XCTest

@testable import Exterm

final class GhosttyTests: XCTestCase {

    func testRuntimeInitializes() {
        let runtime = GhosttyRuntime.shared
        XCTAssertNotNil(runtime.app, "GhosttyRuntime.app should not be nil")
    }

    func testConfigCreated() {
        let runtime = GhosttyRuntime.shared
        XCTAssertNotNil(runtime.config, "GhosttyRuntime.config should not be nil")
    }

    func testTerminalColorHex() {
        let c = TerminalColor(r: 255, g: 128, b: 0)
        // Verify the color can produce valid CGColor/NSColor
        XCTAssertNotNil(c.cgColor)
        XCTAssertNotNil(c.nsColor)
        XCTAssertEqual(c.nsColor.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.nsColor.greenComponent, 128.0 / 255.0, accuracy: 0.01)
    }

    func testThemeAnsiColorCount() {
        XCTAssertEqual(TerminalTheme.defaultDark.ansiColors.count, 16)
    }

    func testResourcesDirDetection() {
        // Derive project root from this source file's path
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot =
            thisFile
            .deletingLastPathComponent()  // ExtermTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root

        // Check bundled resources (created by `make build`)
        let bundled = projectRoot.appendingPathComponent(".build/debug/ghostty-resources/ghostty/shell-integration")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return  // Bundled resources found
        }

        // Check zig-out (raw build output)
        let zigOut = projectRoot.appendingPathComponent("Vendor/ghostty/zig-out/share/ghostty/shell-integration")
        if FileManager.default.fileExists(atPath: zigOut.path) {
            return
        }

        // If neither exists, at least the source should be present
        let srcIntegration = projectRoot.appendingPathComponent("Vendor/ghostty/src/shell-integration")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: srcIntegration.path),
            "Shell integration sources should exist in Vendor/ghostty"
        )
    }
}
