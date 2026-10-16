import Cocoa
import XCTest

@testable import Boo

@MainActor
final class SidebarWindowStateTests: XCTestCase {
    private var originalPerWorkspace = false
    private var originalWidth: CGFloat = 0
    private var originalHidden = false

    override func setUp() async throws {
        try await super.setUp()
        originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        originalWidth = AppSettings.shared.sidebarWidth
        originalHidden = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarPerWorkspaceState = false
        AppSettings.shared.sidebarWidth = 260
        AppSettings.shared.sidebarDefaultHidden = false
    }

    override func tearDown() async throws {
        AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace
        AppSettings.shared.sidebarWidth = originalWidth
        AppSettings.shared.sidebarDefaultHidden = originalHidden
        try await super.tearDown()
    }

    func testWindowsKeepIndependentSidebarState() {
        let first = MainWindowController()
        let second = MainWindowController(restoreSession: false)

        first.sidebarController.persistResolvedState(SidebarWorkspaceState(isVisible: false, width: 340))

        XCTAssertEqual(first.sidebarController.windowState.isVisible, false)
        XCTAssertEqual(first.sidebarController.windowState.width ?? -1, 340, accuracy: 0.001)
        XCTAssertEqual(second.sidebarController.windowState.isVisible, true)
        XCTAssertEqual(second.sidebarController.windowState.width ?? -1, 260, accuracy: 0.001)
        XCTAssertEqual(second.sidebarController.resolveEffectiveSidebarState().width ?? -1, 260, accuracy: 0.001)
    }

    func testPersistRemembersDefaultForNewWindows() {
        let first = MainWindowController()
        first.sidebarController.persistResolvedState(SidebarWorkspaceState(isVisible: false, width: 333))

        XCTAssertTrue(AppSettings.shared.sidebarDefaultHidden)
        XCTAssertEqual(AppSettings.shared.sidebarWidth, 333, accuracy: 0.001)

        let next = MainWindowController(restoreSession: false)
        XCTAssertEqual(next.sidebarController.windowState.isVisible, false)
        XCTAssertEqual(next.sidebarController.windowState.width ?? -1, 333, accuracy: 0.001)
    }

    func testResyncDoesNotOverwriteDefaults() {
        let controller = MainWindowController()
        controller.sidebarController.persistResolvedState(
            SidebarWorkspaceState(isVisible: true, width: 300),
            rememberAsDefault: false
        )

        XCTAssertEqual(controller.sidebarController.windowState.width ?? -1, 300, accuracy: 0.001)
        XCTAssertEqual(AppSettings.shared.sidebarWidth, 260, accuracy: 0.001)
    }

    func testRememberingDefaultsPostsNoSettingsChange() {
        var posted = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        AppSettings.shared.rememberSidebarDefaults(hidden: true, width: 310)

        XCTAssertEqual(posted, 0)
        XCTAssertTrue(AppSettings.shared.sidebarDefaultHidden)
        XCTAssertEqual(AppSettings.shared.sidebarWidth, 310, accuracy: 0.001)
    }
}
