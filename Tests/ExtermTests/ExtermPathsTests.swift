import XCTest

@testable import Exterm

final class ExtermPathsTests: XCTestCase {

    func testConfigDirExists() {
        let path = ExtermPaths.configDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".exterm"))
    }

    func testConfigDirIsInHome() {
        let home = NSHomeDirectory()
        XCTAssertTrue(ExtermPaths.configDir.hasPrefix(home))
    }

    func testSettingsFilePath() {
        XCTAssertTrue(ExtermPaths.settingsFile.hasSuffix("settings.json"))
        XCTAssertTrue(ExtermPaths.settingsFile.contains(".exterm"))
    }

    func testBookmarksFilePath() {
        XCTAssertTrue(ExtermPaths.bookmarksFile.hasSuffix("bookmarks.json"))
        XCTAssertTrue(ExtermPaths.bookmarksFile.contains(".exterm"))
    }

    func testGhosttyConfigFilePath() {
        XCTAssertTrue(ExtermPaths.ghosttyConfigFile.hasSuffix("ghostty.conf"))
        XCTAssertTrue(ExtermPaths.ghosttyConfigFile.contains(".exterm"))
    }

    func testThemesDirExists() {
        let path = ExtermPaths.themesDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix("themes"))
    }

    func testLogsDirExists() {
        let path = ExtermPaths.logsDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix("logs"))
    }
}
