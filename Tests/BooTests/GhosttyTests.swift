import XCTest

@testable import Boo

final class GhosttyTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createShellIntegrationDir(at base: URL) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("shell-integration"),
            withIntermediateDirectories: true
        )
    }

    func testTerminalColorHex() {
        let c = TerminalColor(r: 255, g: 128, b: 0)
        // Verify the color can produce valid CGColor/NSColor
        XCTAssertNotNil(c.cgColor)
        XCTAssertNotNil(c.nsColor)
        XCTAssertEqual(c.nsColor.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.nsColor.greenComponent, 128.0 / 255.0, accuracy: 0.01)
    }

    func testResolveResourcesDirPrefersBundleResources() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let execPath = root.appendingPathComponent("bin/boo")
        try FileManager.default.createDirectory(at: execPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: execPath.path, contents: Data())

        let bundleResources = root.appendingPathComponent("App.app/Contents/Resources/ghostty")
        let bundledResources = execPath.deletingLastPathComponent().appendingPathComponent("ghostty-resources/ghostty")
        try createShellIntegrationDir(at: bundleResources)
        try createShellIntegrationDir(at: bundledResources)

        let resolved = GhosttyRuntime.resolveResourcesDir(
            execPath: execPath.path,
            bundleResourcePath: root.appendingPathComponent("App.app/Contents/Resources").path
        )

        XCTAssertEqual(resolved, bundleResources.path)
    }

    func testResolveResourcesDirFallsBackToBundledResourcesBesideExecutable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let execPath = root.appendingPathComponent("bin/boo")
        try FileManager.default.createDirectory(at: execPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: execPath.path, contents: Data())

        let bundledResources = execPath.deletingLastPathComponent().appendingPathComponent("ghostty-resources/ghostty")
        try createShellIntegrationDir(at: bundledResources)

        let resolved = GhosttyRuntime.resolveResourcesDir(
            execPath: execPath.path,
            bundleResourcePath: nil
        )

        XCTAssertEqual(resolved, bundledResources.path)
    }

    func testResolveResourcesDirFallsBackToVendorTree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let execPath = root.appendingPathComponent(".build/debug/boo")
        try FileManager.default.createDirectory(at: execPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: execPath.path, contents: Data())

        let vendorResources = root.appendingPathComponent("Vendor/ghostty/zig-out/share/ghostty")
        try createShellIntegrationDir(at: vendorResources)

        let resolved = GhosttyRuntime.resolveResourcesDir(
            execPath: execPath.path,
            bundleResourcePath: nil
        )

        XCTAssertEqual(resolved, vendorResources.path)
    }
}
