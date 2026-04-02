import XCTest

@testable import Boo

/// Tests for SidebarFontScale size math and live-settings reflection.
final class SidebarFontScaleTests: XCTestCase {

    // MARK: - Scale math

    func testBaseStepEqualsBase() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertEqual(scale.size(.base), 12)
    }

    func testXsIsThreeQuartersOfBase() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertEqual(scale.size(.xs), (12 * 0.75).rounded())
    }

    func testSmIsSevenEighthsOfBase() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertEqual(scale.size(.sm), (12 * 0.875).rounded())
    }

    func testLgIsOneTwentyFiveOfBase() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertEqual(scale.size(.lg), (12 * 1.125).rounded())
    }

    func testXlIsOneAndQuarterOfBase() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertEqual(scale.size(.xl), (12 * 1.25).rounded())
    }

    func testAllStepsScaleProportionally() {
        // At base=16, verify all steps scale from their multiplier.
        let scale = SidebarFontScale(base: 16)
        XCTAssertEqual(scale.size(.xs), (16 * 0.75).rounded())
        XCTAssertEqual(scale.size(.sm), (16 * 0.875).rounded())
        XCTAssertEqual(scale.size(.base), 16)
        XCTAssertEqual(scale.size(.lg), (16 * 1.125).rounded())
        XCTAssertEqual(scale.size(.xl), (16 * 1.25).rounded())
    }

    func testStepsAreAscending() {
        let scale = SidebarFontScale(base: 12)
        XCTAssertLessThan(scale.size(.xs), scale.size(.sm))
        XCTAssertLessThan(scale.size(.sm), scale.size(.base))
        XCTAssertLessThan(scale.size(.base), scale.size(.lg))
        XCTAssertLessThan(scale.size(.lg), scale.size(.xl))
    }

    // MARK: - buildPluginContext reflects live sidebarFontSize

    @MainActor
    func testBuildPluginContextReflectsUpdatedFontSize() {
        let original = AppSettings.shared.sidebarFontSize
        defer { AppSettings.shared.sidebarFontSize = original }

        let registry = PluginRegistry()
        let terminal = TerminalContext(
            terminalID: UUID(), cwd: "/tmp", remoteSession: nil,
            gitContext: nil, processName: "", paneCount: 1, tabCount: 1)

        AppSettings.shared.sidebarFontSize = 14
        let ctx1 = registry.buildPluginContext(for: "file-tree-local", terminal: terminal)
        XCTAssertEqual(ctx1.fontScale.base, 14)

        // Change font size — buildPluginContext must return the new value,
        // not a stale cached one.
        AppSettings.shared.sidebarFontSize = 18
        let ctx2 = registry.buildPluginContext(for: "file-tree-local", terminal: terminal)
        XCTAssertEqual(
            ctx2.fontScale.base, 18,
            "buildPluginContext must read live sidebarFontSize, not a cached value")
    }

    @MainActor
    func testBuildPluginContextReflectsUpdatedFontName() {
        let originalSize = AppSettings.shared.sidebarFontSize
        let originalName = AppSettings.shared.sidebarFontName
        defer {
            AppSettings.shared.sidebarFontSize = originalSize
            AppSettings.shared.sidebarFontName = originalName
        }

        let registry = PluginRegistry()
        let terminal = TerminalContext(
            terminalID: UUID(), cwd: "/tmp", remoteSession: nil,
            gitContext: nil, processName: "", paneCount: 1, tabCount: 1)

        // Same terminal context — font name change must be captured at construction.
        AppSettings.shared.sidebarFontName = ""
        let ctx1 = registry.buildPluginContext(for: "file-tree-local", terminal: terminal)
        XCTAssertEqual(ctx1.fontScale.fontName, "")

        AppSettings.shared.sidebarFontName = "Menlo"
        let ctx2 = registry.buildPluginContext(for: "file-tree-local", terminal: terminal)
        XCTAssertEqual(
            ctx2.fontScale.fontName, "Menlo",
            "fontName must be captured at buildPluginContext call time, not lazily")
    }
}
