import XCTest
@testable import Exterm

final class LayoutSettingsTests: XCTestCase {

    override func tearDown() {
        // Reset to defaults
        UserDefaults.standard.removeObject(forKey: "sidebarPosition")
        UserDefaults.standard.removeObject(forKey: "workspaceBarPosition")
        UserDefaults.standard.removeObject(forKey: "sidebarDensity")
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

    func testEnumLabels() {
        XCTAssertEqual(SidebarPosition.left.label, "Left")
        XCTAssertEqual(SidebarPosition.right.label, "Right")
        XCTAssertEqual(WorkspaceBarPosition.left.label, "Left")
        XCTAssertEqual(WorkspaceBarPosition.top.label, "Top")
        XCTAssertEqual(WorkspaceBarPosition.right.label, "Right")
        XCTAssertEqual(SidebarDensity.comfortable.label, "Comfortable")
        XCTAssertEqual(SidebarDensity.compact.label, "Compact")
    }
}
