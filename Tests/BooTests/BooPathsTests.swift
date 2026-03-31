import XCTest

@testable import Boo

final class BooPathsTests: XCTestCase {

    func testConfigDirExists() {
        let path = BooPaths.configDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".boo"))
    }

    func testConfigDirIsInHome() {
        let home = NSHomeDirectory()
        XCTAssertTrue(BooPaths.configDir.hasPrefix(home))
    }

    func testThemesDirExists() {
        let path = BooPaths.themesDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix("themes"))
    }

    func testLogsDirExists() {
        let path = BooPaths.logsDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix("logs"))
    }
}
