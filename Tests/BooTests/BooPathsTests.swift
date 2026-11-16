import XCTest

@testable import Boo

final class BooPathsTests: XCTestCase {

    func testConfigDirExists() {
        let path = BooPaths.configDir
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".boo"))
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

    func testRestrictConfigDirMakesItOwnerOnly() throws {
        let dir = NSTemporaryDirectory() + "boo-perm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        BooPaths.restrictConfigDir(dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testWriteAtomicallyKeepsASymlinkAndTheFileMode() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "boo-write-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let real = dir + "/real.rc"
        let link = dir + "/link.rc"
        try Data("old".utf8).write(to: URL(fileURLWithPath: real))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: real)

        try BooPaths.writeAtomically(Data("new".utf8), toFile: link)

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), real)
        XCTAssertEqual(try String(contentsOfFile: real, encoding: .utf8), "new")
        let mode = try fm.attributesOfItem(atPath: real)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
