import XCTest

@testable import Exterm

/// Tests for sidebarPluginOrder persistence and ordered insertion.
@MainActor
final class SidebarPluginOrderTests: XCTestCase {

    private var originalOrder: [String] = []
    private var originalEnabled: [String] = []

    override func setUp() {
        super.setUp()
        originalOrder = AppSettings.shared.sidebarPluginOrder
        originalEnabled = AppSettings.shared.defaultEnabledPluginIDs
    }

    override func tearDown() {
        AppSettings.shared.sidebarPluginOrder = originalOrder
        AppSettings.shared.defaultEnabledPluginIDs = originalEnabled
        super.tearDown()
    }

    // MARK: - Round-trip persistence

    func testSidebarPluginOrderRoundTrip() {
        let order = ["git-panel", "file-tree-local", "bookmarks", "docker"]
        AppSettings.shared.sidebarPluginOrder = order
        XCTAssertEqual(AppSettings.shared.sidebarPluginOrder, order)
    }

    func testSidebarPluginOrderDefaultsToEmpty() {
        UserDefaults.standard.removeObject(forKey: "sidebarPluginOrder")
        XCTAssertEqual(AppSettings.shared.sidebarPluginOrder, [])
    }

    func testSidebarPluginOrderPersistedToSettingsJSON() {
        let order = ["bookmarks", "git-panel", "file-tree-local"]
        AppSettings.shared.sidebarPluginOrder = order

        let path = ExtermPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }
        XCTAssertEqual(
            json["sidebarPluginOrder"] as? [String], order,
            "sidebarPluginOrder should be persisted in settings.json")
    }

    // MARK: - Ordered insertion in defaultEnabledPluginIDs

    func testAddPluginRespectsCanonicalOrder() {
        // Set canonical order: A, B, C, D
        AppSettings.shared.sidebarPluginOrder = ["A", "B", "C", "D"]
        // Current enabled: A, C
        AppSettings.shared.defaultEnabledPluginIDs = ["A", "C"]

        // Add B — should be inserted between A and C (respecting canonical order)
        AppSettings.shared.updateDefaultEnabledPlugins(add: "B")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "B", "C"],
            "B should be inserted at its canonical position between A and C")
    }

    func testAddPluginAtEndWhenLastInCanonicalOrder() {
        AppSettings.shared.sidebarPluginOrder = ["A", "B", "C", "D"]
        AppSettings.shared.defaultEnabledPluginIDs = ["A", "B"]

        AppSettings.shared.updateDefaultEnabledPlugins(add: "D")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "B", "D"],
            "D should be appended at end (canonical position is after B)")
    }

    func testAddPluginAtStartWhenFirstInCanonicalOrder() {
        AppSettings.shared.sidebarPluginOrder = ["A", "B", "C", "D"]
        AppSettings.shared.defaultEnabledPluginIDs = ["C", "D"]

        AppSettings.shared.updateDefaultEnabledPlugins(add: "A")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "C", "D"],
            "A should be inserted at start (canonical position is before C)")
    }

    func testAddUnknownPluginAppendsToEnd() {
        AppSettings.shared.sidebarPluginOrder = ["A", "B", "C"]
        AppSettings.shared.defaultEnabledPluginIDs = ["A", "B"]

        AppSettings.shared.updateDefaultEnabledPlugins(add: "unknown-plugin")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "B", "unknown-plugin"],
            "Plugin not in canonical order should be appended at end")
    }

    func testAddPluginWithEmptyCanonicalOrder() {
        AppSettings.shared.sidebarPluginOrder = []
        AppSettings.shared.defaultEnabledPluginIDs = ["A"]

        AppSettings.shared.updateDefaultEnabledPlugins(add: "B")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "B"],
            "Without canonical order, plugin should be appended")
    }

    func testRemovePlugin() {
        AppSettings.shared.defaultEnabledPluginIDs = ["A", "B", "C"]

        AppSettings.shared.updateDefaultEnabledPlugins(remove: "B")

        XCTAssertEqual(AppSettings.shared.defaultEnabledPluginIDs, ["A", "C"])
    }

    func testAddDuplicateIgnored() {
        AppSettings.shared.defaultEnabledPluginIDs = ["A", "B"]

        AppSettings.shared.updateDefaultEnabledPlugins(add: "A")

        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, ["A", "B"],
            "Adding a duplicate should be a no-op")
    }
}
