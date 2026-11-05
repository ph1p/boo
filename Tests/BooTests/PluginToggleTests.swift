import XCTest

@testable import Boo

/// Tests that enabling/disabling plugins via disabledPluginIDs works correctly.
@MainActor
final class PluginToggleTests: XCTestCase {

    private var originalDisabled: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            originalDisabled = AppSettings.shared.disabledPluginIDs
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppSettings.shared.disabledPluginIDs = originalDisabled
        }
        try await super.tearDown()
    }

    // MARK: - disabledPluginIDs toggling

    func testEnablePlugin() {
        AppSettings.shared.disabledPluginIDs = ["git-panel", "bookmarks"]

        var disabled = AppSettings.shared.disabledPluginIDs
        disabled.removeAll { $0 == "git-panel" }
        AppSettings.shared.disabledPluginIDs = disabled

        XCTAssertFalse(
            AppSettings.shared.disabledPluginIDs.contains("git-panel"),
            "Plugin should be absent from disabledPluginIDs after being re-enabled")
        XCTAssertTrue(
            AppSettings.shared.isPluginEnabled("git-panel"),
            "isPluginEnabled should return true for a re-enabled plugin")
        XCTAssertTrue(
            AppSettings.shared.disabledPluginIDs.contains("bookmarks"),
            "Other plugins should remain disabled")
    }

    func testDisabledPluginIDsSetCacheIsInvalidated() {
        AppSettings.shared.disabledPluginIDs = []
        XCTAssertTrue(AppSettings.shared.isPluginEnabled("bookmarks"))

        AppSettings.shared.disabledPluginIDs = ["bookmarks"]
        XCTAssertFalse(
            AppSettings.shared.isPluginEnabled("bookmarks"),
            "Cache should be invalidated after updating disabledPluginIDs")
    }
}
