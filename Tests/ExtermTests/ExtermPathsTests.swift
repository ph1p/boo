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
