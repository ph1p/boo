import XCTest

@testable import Boo

final class WorkspaceSettingsTests: XCTestCase {
    func testRoundTripAndEmpty() throws {
        XCTAssertTrue(WorkspaceSettings().isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(WorkspaceSettings.self, from: Data("{}".utf8)).isEmpty)

        let settings = WorkspaceSettings(
            defaultProfile: "prod", sidebarDefaultTab: "git-panel", sidebarPosition: SidebarPosition.left.rawValue,
            tabOverflowMode: TabOverflowMode.vertical.rawValue, statusBarHiddenSegments: ["time"])
        XCTAssertFalse(settings.isEmpty)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: data), settings)
    }

    func testEffectiveSettingsPreferWorkspaceValues() {
        let inherited = EffectiveSettings.resolve(
            workspace: WorkspaceSettings(), sidebarPosition: .right, tabOverflowMode: .wrap, defaultProfile: "global")
        XCTAssertEqual(inherited.sidebarPosition, .right)
        XCTAssertEqual(inherited.tabOverflowMode, .wrap)
        XCTAssertNil(inherited.statusBarHiddenSegments)
        XCTAssertNil(inherited.sidebarDefaultTab)
        XCTAssertEqual(inherited.defaultProfile, "global")
        XCTAssertEqual(
            inherited,
            EffectiveSettings.resolve(
                workspace: nil, sidebarPosition: .right, tabOverflowMode: .wrap, defaultProfile: "global"))

        let overridden = EffectiveSettings.resolve(
            workspace: WorkspaceSettings(
                defaultProfile: "prod", sidebarDefaultTab: "git-panel", sidebarPosition: 0, tabOverflowMode: 2,
                statusBarHiddenSegments: []),
            sidebarPosition: .right, tabOverflowMode: .wrap, defaultProfile: "global")
        XCTAssertEqual(overridden.sidebarPosition, .left)
        XCTAssertEqual(overridden.tabOverflowMode, .vertical)
        XCTAssertEqual(overridden.statusBarHiddenSegments, [])
        XCTAssertEqual(overridden.sidebarDefaultTab, "git-panel")
        XCTAssertEqual(overridden.defaultProfile, "prod")
    }

    func testUnknownRawValuesInherit() {
        let effective = EffectiveSettings.resolve(
            workspace: WorkspaceSettings(sidebarPosition: 9, tabOverflowMode: 9),
            sidebarPosition: .left, tabOverflowMode: .scroll, defaultProfile: nil)
        XCTAssertEqual(effective.sidebarPosition, .left)
        XCTAssertEqual(effective.tabOverflowMode, .scroll)
    }

    @MainActor
    func testSessionKeepsWorkspaceSettings() throws {
        let state = AppState()
        let plain = Workspace(folderPath: "/tmp")
        let custom = Workspace(folderPath: "/tmp")
        custom.settings.defaultProfile = "prod"
        custom.settings.statusBarHiddenSegments = ["time"]
        state.addWorkspace(plain)
        state.addWorkspace(custom)

        let window = SessionStore.buildWindow(appState: state)
        XCTAssertNil(window.workspaces[0].settings)
        XCTAssertEqual(window.workspaces[1].settings, custom.settings)

        // A workspace without overrides is saved as before, so older sessions decode the same way.
        let data = try JSONEncoder().encode(window.workspaces[0])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"settings\""))
        XCTAssertNil(try JSONDecoder().decode(SessionWorkspace.self, from: data).settings)

        let restored = SessionStore.workspaces(from: window)
        XCTAssertTrue(restored[0].settings.isEmpty)
        XCTAssertEqual(restored[1].settings, custom.settings)
    }

    @MainActor
    func testStatusBarOverrideDecidesForEverySegment() {
        let bar = StatusBarView(frame: .zero)
        let settings = AppSettings.shared
        let previous = settings.statusBarShowTime
        defer { settings.statusBarShowTime = previous }
        settings.statusBarShowTime = false

        XCTAssertTrue(bar.isSegmentHidden("time"))
        bar.hiddenSegmentsOverride = ["ports"]
        XCTAssertFalse(bar.isSegmentHidden("time"))
        XCTAssertTrue(bar.isSegmentHidden("ports"))
        bar.hiddenSegmentsOverride = nil
        XCTAssertTrue(bar.isSegmentHidden("time"))
    }
}
