import XCTest

@testable import Boo

/// Tests for sidebarTabOrder persistence.
@MainActor
final class SidebarPluginOrderTests: XCTestCase {

    private var originalOrder: [String] = []

    override func setUp() {
        super.setUp()
        originalOrder = AppSettings.shared.sidebarTabOrder
    }

    override func tearDown() {
        AppSettings.shared.sidebarTabOrder = originalOrder
        super.tearDown()
    }

    // MARK: - Round-trip persistence

    func testSidebarTabOrderRoundTrip() {
        let order = ["git-panel", "file-tree-local", "bookmarks", "docker"]
        AppSettings.shared.sidebarTabOrder = order
        XCTAssertEqual(AppSettings.shared.sidebarTabOrder, order)
    }

    func testSidebarTabOrderDefaultsToEmpty() {
        UserDefaults.standard.removeObject(forKey: "sidebarPluginOrder")
        XCTAssertEqual(AppSettings.shared.sidebarTabOrder, [])
    }

    func testSidebarTabOrderPersistedToSettingsJSON() {
        let order = ["bookmarks", "git-panel", "file-tree-local"]
        AppSettings.shared.sidebarTabOrder = order

        let path = BooPaths.settingsFile
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
}
