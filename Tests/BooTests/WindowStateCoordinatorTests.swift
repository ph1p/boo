import XCTest

@testable import Boo

@MainActor
final class WindowStateCoordinatorTests: XCTestCase {
    func testLoadSidebarStateFromSettingsRestoresGlobalSidebarState() {
        let settings = AppSettings.shared
        let originalGlobal = settings.sidebarGlobalState
        settings.sidebarGlobalState = true
        defer { settings.sidebarGlobalState = originalGlobal }

        settings.saveSidebarState(
            heights: ["files": 200],
            order: ["git-panel": ["files"]],
            globalExpandedSectionIDs: ["files"],
            globalUserCollapsedSectionIDs: ["history"],
            globalSelectedPluginTabID: "git-panel",
            globalScrollOffsets: ["__global__:files": CGPoint(x: 0, y: 30)]
        )

        let coordinator = WindowStateCoordinator(
            bridge: TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "/tmp"),
            pluginRegistry: PluginRegistry()
        )

        XCTAssertEqual(coordinator.sidebarSectionHeights["files"] ?? -1, 200, accuracy: 0.1)
        XCTAssertEqual(coordinator.sidebarSectionOrder["git-panel"] ?? [], ["files"])
        XCTAssertEqual(coordinator.expandedPluginIDs, Set(["files"]))
        XCTAssertEqual(coordinator.userCollapsedSectionIDs, Set(["history"]))
        XCTAssertEqual(coordinator.selectedPluginTabID, "git-panel")
        XCTAssertEqual(coordinator.sidebarScrollOffsets["__global__:files"]?.y ?? -1, 30, accuracy: 0.1)
    }

    func testSaveSidebarStateToSettingsPersistsGlobalSidebarStateWhenEnabled() {
        let settings = AppSettings.shared
        let originalGlobal = settings.sidebarGlobalState
        settings.sidebarGlobalState = true
        defer { settings.sidebarGlobalState = originalGlobal }

        let coordinator = WindowStateCoordinator(
            bridge: TerminalBridge(paneID: UUID(), workspaceID: UUID(), workingDirectory: "/tmp"),
            pluginRegistry: PluginRegistry()
        )
        coordinator.sidebarSectionHeights = ["files": 220]
        coordinator.sidebarSectionOrder = ["git-panel": ["files", "history"]]
        coordinator.expandedPluginIDs = ["files", "history"]
        coordinator.userCollapsedSectionIDs = ["status"]
        coordinator.selectedPluginTabID = "git-panel"
        coordinator.sidebarScrollOffsets = ["__global__:files": CGPoint(x: 0, y: 55)]

        coordinator.saveSidebarStateToSettings()

        XCTAssertEqual(settings.sidebarSectionHeights["files"] ?? -1, 220, accuracy: 0.1)
        XCTAssertEqual(settings.sidebarSectionOrder["git-panel"] ?? [], ["files", "history"])
        XCTAssertEqual(settings.sidebarGlobalExpandedSectionIDs, Set(["files", "history"]))
        XCTAssertEqual(settings.sidebarGlobalUserCollapsedSectionIDs, Set(["status"]))
        XCTAssertEqual(settings.sidebarGlobalSelectedPluginTabID, "git-panel")
        XCTAssertEqual(settings.sidebarGlobalScrollOffsets["__global__:files"]?.y ?? -1, 55, accuracy: 0.1)
    }
}
