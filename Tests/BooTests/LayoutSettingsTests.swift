import XCTest

@testable import Boo

final class LayoutSettingsTests: XCTestCase {

    override func tearDown() {
        // Reset to defaults
        UserDefaults.standard.removeObject(forKey: "sidebarPosition")
        UserDefaults.standard.removeObject(forKey: "workspaceBarPosition")
        UserDefaults.standard.removeObject(forKey: "sidebarDensity")
        UserDefaults.standard.removeObject(forKey: "sidebarDefaultHidden")
        super.tearDown()
    }

    func testSidebarPositionDefault() {
        UserDefaults.standard.removeObject(forKey: "sidebarPosition")
        XCTAssertEqual(AppSettings.shared.sidebarPosition, .right)
    }

    func testSidebarPositionRoundTrip() {
        AppSettings.shared.sidebarPosition = .left
        XCTAssertEqual(AppSettings.shared.sidebarPosition, .left)
        AppSettings.shared.sidebarPosition = .right
        XCTAssertEqual(AppSettings.shared.sidebarPosition, .right)
    }

    func testWorkspaceBarPositionDefault() {
        UserDefaults.standard.removeObject(forKey: "workspaceBarPosition")
        XCTAssertEqual(AppSettings.shared.workspaceBarPosition, .left)
    }

    func testWorkspaceBarPositionRoundTrip() {
        AppSettings.shared.workspaceBarPosition = .top
        XCTAssertEqual(AppSettings.shared.workspaceBarPosition, .top)
        AppSettings.shared.workspaceBarPosition = .right
        XCTAssertEqual(AppSettings.shared.workspaceBarPosition, .right)
        AppSettings.shared.workspaceBarPosition = .left
        XCTAssertEqual(AppSettings.shared.workspaceBarPosition, .left)
    }

    func testSidebarDensityDefault() {
        UserDefaults.standard.removeObject(forKey: "sidebarDensity")
        XCTAssertEqual(AppSettings.shared.sidebarDensity, .comfortable)
    }

    func testSidebarDensityAlwaysComfortable() {
        UserDefaults.standard.set(SidebarDensity.compact.rawValue, forKey: "sidebarDensity")
        XCTAssertEqual(AppSettings.shared.sidebarDensity, .comfortable)

        UserDefaults.standard.set(SidebarDensity.comfortable.rawValue, forKey: "sidebarDensity")
        XCTAssertEqual(AppSettings.shared.sidebarDensity, .comfortable)
    }

    // MARK: - Sidebar Default Hidden

    func testSidebarDefaultHiddenDefault() {
        UserDefaults.standard.removeObject(forKey: "sidebarDefaultHidden")
        XCTAssertFalse(AppSettings.shared.sidebarDefaultHidden, "Sidebar should be visible by default")
    }

    func testSidebarDefaultHiddenRoundTrip() {
        AppSettings.shared.sidebarDefaultHidden = true
        XCTAssertTrue(AppSettings.shared.sidebarDefaultHidden)
        AppSettings.shared.sidebarDefaultHidden = false
        XCTAssertFalse(AppSettings.shared.sidebarDefaultHidden)
    }

    func testSidebarDefaultHiddenNotifiesLayoutTopic() {
        let exp = expectation(description: "layout notification")
        exp.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { notification in
            if let topic = notification.userInfo?["topic"] as? String, topic == "layout" {
                exp.fulfill()
            }
        }

        AppSettings.shared.sidebarDefaultHidden = true

        waitForExpectations(timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        AppSettings.shared.sidebarDefaultHidden = false
    }

    func testSidebarDefaultHiddenPersistedInJSON() {
        let original = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarDefaultHidden = true
        defer { AppSettings.shared.sidebarDefaultHidden = original }

        let path = BooPaths.settingsFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Could not read settings.json")
            return
        }
        XCTAssertEqual(
            json["sidebarDefaultHidden"] as? Bool, true,
            "sidebarDefaultHidden should be persisted in settings.json")
    }

    // MARK: - Sidebar User Hidden Flag

    @MainActor
    func testUserToggleSetsUserHiddenFlag() {
        let wc = MainWindowController()
        // Starts visible (default setting is false)
        XCTAssertTrue(wc.sidebarVisible)
        XCTAssertFalse(wc.sidebarUserHidden)

        // User hides sidebar
        wc.toggleSidebar(userInitiated: true)
        XCTAssertFalse(wc.sidebarVisible)
        XCTAssertTrue(wc.sidebarUserHidden, "User-initiated hide should set sidebarUserHidden")

        // User shows sidebar again
        wc.toggleSidebar(userInitiated: true)
        XCTAssertTrue(wc.sidebarVisible)
        XCTAssertFalse(wc.sidebarUserHidden, "User-initiated show should clear sidebarUserHidden")
    }

    @MainActor
    func testProgrammaticToggleDoesNotSetUserHiddenFlag() {
        let wc = MainWindowController()
        XCTAssertFalse(wc.sidebarUserHidden)

        // Programmatic hide (e.g. no visible plugins)
        wc.toggleSidebar(userInitiated: false)
        XCTAssertFalse(wc.sidebarVisible)
        XCTAssertFalse(wc.sidebarUserHidden, "Programmatic hide should not set sidebarUserHidden")
    }

    @MainActor
    func testDefaultHiddenSetsUserHiddenFlag() {
        let original = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarDefaultHidden = true
        defer { AppSettings.shared.sidebarDefaultHidden = original }

        let wc = MainWindowController()
        XCTAssertFalse(wc.sidebarVisible, "Sidebar should start hidden when setting is true")
        XCTAssertTrue(wc.sidebarUserHidden, "sidebarUserHidden should match default-hidden setting")
    }

    @MainActor
    func testDefaultVisibleClearsUserHiddenFlag() {
        let original = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarDefaultHidden = false
        defer { AppSettings.shared.sidebarDefaultHidden = original }

        let wc = MainWindowController()
        XCTAssertTrue(wc.sidebarVisible, "Sidebar should start visible when setting is false")
        XCTAssertFalse(wc.sidebarUserHidden)
    }

}
