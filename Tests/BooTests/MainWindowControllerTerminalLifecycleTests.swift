import XCTest

@testable import Boo

@MainActor
final class MainWindowControllerTerminalLifecycleTests: XCTestCase {
    private func sidebarWidth(for windowController: MainWindowController) -> CGFloat {
        let sidebarIndex = windowController.currentSidebarPosition == .left ? 0 : 1
        guard sidebarIndex < windowController.mainSplitView.subviews.count else { return 0 }
        return windowController.mainSplitView.subviews[sidebarIndex].frame.width
    }

    private func dividerPosition(
        forSidebarWidth width: CGFloat,
        in windowController: MainWindowController
    ) -> CGFloat {
        switch windowController.currentSidebarPosition {
        case .left:
            return width
        case .right:
            return windowController.mainSplitView.bounds.width
                - width
                - windowController.mainSplitView.dividerThickness
        }
    }

    final class TerminalCloseSpyPlugin: BooPluginProtocol {
        let manifest = PluginManifest(
            id: "terminal-close-spy",
            name: "Terminal Close Spy",
            version: "1.0.0",
            icon: "scope",
            description: nil,
            when: nil,
            runtime: nil,
            capabilities: nil,
            statusBar: nil,
            settings: nil
        )

        var actions: PluginActions?
        var services: PluginServices?
        var hostActions: PluginHostActions?
        var onRequestCycleRerun: (() -> Void)?
        var subscribedEvents: Set<PluginEvent> { [.terminalClosed] }

        private(set) var closedTerminalIDs: [UUID] = []

        func terminalClosed(terminalID: UUID) {
            closedTerminalIDs.append(terminalID)
        }
    }

    func testForceCloseWorkspaceEmitsTerminalClosedForAllTabs() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let windowController = MainWindowController()
        let spy = TerminalCloseSpyPlugin()
        windowController.pluginRegistry.register(spy)

        // Use the first workspace (index 0), which may have been restored from a session.
        guard let workspace = windowController.appState.workspaces.first,
            let pane = workspace.pane(for: workspace.activePaneID)
        else {
            XCTFail("Expected at least one workspace with an active pane")
            return
        }

        // Snapshot all tab IDs in workspace 0 before adding our extra tab.
        let initialTabIDs = Set(workspace.panes.values.flatMap { $0.tabs.map(\.id) })
        XCTAssertFalse(initialTabIDs.isEmpty, "Expected at least one existing tab")

        _ = pane.addTab(workingDirectory: "/tmp/extra-tab")
        let extraTabID = pane.activeTab?.id

        let expectedTabIDs = initialTabIDs.union([extraTabID].compactMap { $0 })

        windowController.forceCloseWorkspace(at: 0)

        XCTAssertEqual(
            Set(spy.closedTerminalIDs),
            expectedTabIDs,
            "Closing a workspace should emit terminalClosed for every tab it owns"
        )
    }

    func testProcessChangeRefreshesStatusBarAfterPluginCycle() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let windowController = MainWindowController()
        guard let workspace = windowController.activeWorkspace else {
            XCTFail("Expected an active workspace")
            return
        }

        let paneID = workspace.activePaneID
        windowController.statusBar.runningProcess = ""

        windowController.bridge.handleTitleChange(title: "node server.js", paneID: paneID)
        XCTAssertEqual(windowController.bridge.state.foregroundProcess, "node")

        windowController.runPluginCycle(reason: .processChanged)

        XCTAssertEqual(AppStore.shared.context.processName, "node")
        XCTAssertEqual(
            windowController.statusBar.runningProcess,
            "node",
            "Status bar should refresh from the updated pane-scoped AppStore context"
        )
    }

    func testSplitPaneRemapsSidebarScrollOffsetsToNewTerminal() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let workspace = windowController.activeWorkspace,
            let parentPane = workspace.pane(for: workspace.activePaneID),
            let parentTab = parentPane.activeTab
        else {
            XCTFail("Expected an active workspace with an active tab")
            return
        }

        let heights: [String: CGFloat] = ["bookmarks": 172]
        let offsets: [String: CGPoint] = [
            "\(parentTab.id.uuidString):bookmarks": CGPoint(x: 0, y: 61)
        ]
        parentPane.updatePluginState(
            at: parentPane.activeTabIndex,
            expanded: ["file-tree-local", "bookmarks"],
            sidebarSectionHeights: heights,
            sidebarScrollOffsets: offsets
        )

        windowController.splitActivePane(direction: .horizontal)

        guard let newPane = workspace.pane(for: workspace.activePaneID),
            let newTab = newPane.activeTab
        else {
            XCTFail("Expected split to create a new active pane")
            return
        }

        XCTAssertEqual(newPane.activeTab!.state.sidebarSectionHeights, heights)
        XCTAssertEqual(
            newTab.state.sidebarScrollOffsets["\(newTab.id.uuidString):bookmarks"]?.y ?? -1,
            61,
            accuracy: 0.1
        )
        XCTAssertNil(newTab.state.sidebarScrollOffsets["\(parentTab.id.uuidString):bookmarks"])
    }

    func testWorkspaceSwitchSavesAndRestoresSidebarState() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace,
            let firstTab = firstWorkspace.pane(for: firstWorkspace.activePaneID)?.activeTab
        else {
            XCTFail("Expected an initial workspace")
            return
        }

        let firstExpanded: Set<String> = ["file-tree-local", "bookmarks"]
        let firstHeights: [String: CGFloat] = ["bookmarks": 196]
        let firstOffsets: [String: CGPoint] = [
            "\(firstTab.id.uuidString):bookmarks": CGPoint(x: 0, y: 44)
        ]

        windowController.expandedPluginIDs = firstExpanded
        windowController.savedSidebarHeights = firstHeights
        windowController.savedSidebarScrollOffsets = firstOffsets

        windowController.openWorkspace(path: "/tmp/boo-sidebar-state")

        XCTAssertEqual(
            firstWorkspace.pane(for: firstWorkspace.activePaneID)?.activeTab?.state.sidebarSectionHeights,
            firstHeights
        )
        XCTAssertEqual(
            firstWorkspace.pane(for: firstWorkspace.activePaneID)?.activeTab?.state.sidebarScrollOffsets[
                "\(firstTab.id.uuidString):bookmarks"]?.y ?? -1,
            44,
            accuracy: 0.1
        )

        guard let secondWorkspace = windowController.activeWorkspace,
            let secondTab = secondWorkspace.pane(for: secondWorkspace.activePaneID)?.activeTab
        else {
            XCTFail("Expected a second workspace after opening one")
            return
        }

        let secondExpanded: Set<String> = ["file-tree-local", "git-panel"]
        let secondHeights: [String: CGFloat] = ["git-panel": 155]
        let secondOffsets: [String: CGPoint] = [
            "\(secondTab.id.uuidString):git-panel": CGPoint(x: 0, y: 28)
        ]

        windowController.expandedPluginIDs = secondExpanded
        windowController.savedSidebarHeights = secondHeights
        windowController.savedSidebarScrollOffsets = secondOffsets

        windowController.activateWorkspace(0)

        XCTAssertEqual(windowController.expandedPluginIDs, firstExpanded)
        XCTAssertEqual(windowController.savedSidebarHeights, firstHeights)
        XCTAssertEqual(
            windowController.savedSidebarScrollOffsets["\(firstTab.id.uuidString):bookmarks"]?.y ?? -1,
            44,
            accuracy: 0.1
        )
        XCTAssertEqual(windowController.previousFocusedTabID, firstTab.id)
    }

    func testWorkspaceSwitchRestoresSidebarVisibilityAndWidthPerWorkspace() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }

        let firstWidth: CGFloat = 278
        firstWorkspace.sidebarState = SidebarWorkspaceState(isVisible: true, width: firstWidth)
        windowController.activateWorkspace(0)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), firstWidth, accuracy: 2)

        windowController.openWorkspace(path: "/tmp/boo-sidebar-workspace-b")
        guard let secondWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected a second workspace")
            return
        }

        windowController.toggleSidebar(userInitiated: true)
        XCTAssertFalse(windowController.sidebarVisible)
        XCTAssertEqual(secondWorkspace.sidebarState.isVisible, false)

        let secondWidth: CGFloat = 344
        secondWorkspace.sidebarState.width = secondWidth
        windowController.toggleSidebar(userInitiated: true)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), secondWidth, accuracy: 2)

        windowController.activateWorkspace(0)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), firstWidth, accuracy: 2)
        XCTAssertEqual(firstWorkspace.sidebarState.isVisible, true)

        windowController.activateWorkspace(1)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), secondWidth, accuracy: 2)
        XCTAssertEqual(secondWorkspace.sidebarState.isVisible, true)
    }

    func testReopenRestoresWorkspaceSpecificSidebarState() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-sidebar-restore-\(UUID().uuidString).json"
        )
        SessionStore.overrideFilePathForTesting(tempFile)
        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
            SessionStore.overrideFilePathForTesting(nil)
        }

        let state = AppState()
        let firstWorkspace = Workspace(folderPath: "/tmp")
        firstWorkspace.sidebarState = SidebarWorkspaceState(isVisible: true, width: 278)
        let secondWorkspace = Workspace(folderPath: "/tmp")
        secondWorkspace.sidebarState = SidebarWorkspaceState(isVisible: false, width: 344)
        state.addWorkspace(firstWorkspace)
        state.addWorkspace(secondWorkspace)
        state.setActiveWorkspace(1)
        SessionStore.save(appState: state)

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        XCTAssertEqual(windowController.appState.activeWorkspaceIndex, 1)
        XCTAssertFalse(windowController.sidebarVisible)

        windowController.toggleSidebar(userInitiated: true)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), 344, accuracy: 2)

        windowController.activateWorkspace(0)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), 278, accuracy: 2)

        windowController.activateWorkspace(1)
        XCTAssertFalse(windowController.sidebarVisible)
        windowController.toggleSidebar(userInitiated: true)
        XCTAssertEqual(sidebarWidth(for: windowController), 344, accuracy: 2)
    }

    func testSaveSessionCapturesActiveWorkspaceSidebarStateWithoutSwitching() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-sidebar-save-\(UUID().uuidString).json"
        )
        SessionStore.overrideFilePathForTesting(tempFile)
        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
            SessionStore.overrideFilePathForTesting(nil)
        }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let workspace = windowController.activeWorkspace else {
            XCTFail("Expected an active workspace")
            return
        }

        let width: CGFloat = 321
        workspace.sidebarState.width = width
        if !windowController.sidebarVisible {
            windowController.toggleSidebar(userInitiated: true)
        }
        let position = dividerPosition(forSidebarWidth: width, in: windowController)
        windowController.mainSplitView.setPosition(position, ofDividerAt: 0)

        windowController.saveSession()

        guard let snapshot = SessionStore.load(),
            let savedWorkspace = snapshot.workspaces.first
        else {
            XCTFail("Expected a saved session snapshot")
            return
        }
        XCTAssertEqual(savedWorkspace.sidebarIsVisible, true)
        XCTAssertEqual(savedWorkspace.sidebarWidth ?? -1, width, accuracy: 2)
    }

    func testHidingSidebarPreservesWorkspaceWidth() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let workspace = windowController.activeWorkspace else {
            XCTFail("Expected an active workspace")
            return
        }

        let width: CGFloat = 333
        workspace.sidebarState.width = width
        windowController.activateWorkspace(0)
        XCTAssertEqual(sidebarWidth(for: windowController), width, accuracy: 2)

        windowController.toggleSidebar(userInitiated: true)

        XCTAssertFalse(windowController.sidebarVisible)
        XCTAssertEqual(workspace.sidebarState.isVisible, false)
        XCTAssertEqual(workspace.sidebarState.width ?? -1, width, accuracy: 2)
    }

    func testResetSidebarWidthToDefaultRestoresAppDefaultWidth() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let workspace = windowController.activeWorkspace else {
            XCTFail("Expected an active workspace")
            return
        }

        let originalDefault = AppSettings.shared.sidebarWidth
        AppSettings.shared.sidebarWidth = 250
        defer { AppSettings.shared.sidebarWidth = originalDefault }

        workspace.sidebarState.width = 336
        windowController.activateWorkspace(0)
        XCTAssertEqual(sidebarWidth(for: windowController), 336, accuracy: 2)

        windowController.resetSidebarWidthToDefault()

        XCTAssertEqual(sidebarWidth(for: windowController), 250, accuracy: 2)
        XCTAssertEqual(workspace.sidebarState.width ?? -1, 250, accuracy: 2)
    }

    func testSidebarWidthPersistenceSnapsToDevicePixels() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let workspace = windowController.activeWorkspace else {
            XCTFail("Expected an active workspace")
            return
        }

        if !windowController.sidebarVisible {
            windowController.toggleSidebar(userInitiated: true)
        }

        let requestedWidth: CGFloat = 287.3
        let scale = max(windowController.window?.backingScaleFactor ?? 1, 1)
        let expectedWidth = (requestedWidth * scale).rounded() / scale
        let position = dividerPosition(forSidebarWidth: requestedWidth, in: windowController)

        windowController.mainSplitView.setPosition(position, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()

        XCTAssertEqual(workspace.sidebarState.width ?? -1, expectedWidth, accuracy: 0.001)
    }

    func testNewWorkspaceUsesDefaultSidebarWidthPerWorkspaceMode() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        let originalDefaultWidth = AppSettings.shared.sidebarWidth
        AppSettings.shared.sidebarPerWorkspaceState = true
        AppSettings.shared.sidebarWidth = 250
        defer {
            AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace
            AppSettings.shared.sidebarWidth = originalDefaultWidth
        }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }

        let width: CGFloat = 307.5
        if !windowController.sidebarVisible {
            windowController.toggleSidebar(userInitiated: true)
        }
        let position = dividerPosition(forSidebarWidth: width, in: windowController)
        windowController.mainSplitView.setPosition(position, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()
        let expectedVisibility = firstWorkspace.sidebarState.isVisible

        windowController.openWorkspace(path: "/tmp/boo-sidebar-per-workspace-new")

        guard let secondWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected new active workspace")
            return
        }

        XCTAssertEqual(secondWorkspace.sidebarState.width ?? -1, width, accuracy: 0.001)
        XCTAssertEqual(secondWorkspace.sidebarState.isVisible, expectedVisibility)
        XCTAssertEqual(sidebarWidth(for: windowController), width, accuracy: 1)
    }

    func testMultipleNewWorkspacesInheritSameLiveSidebarWidth() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        AppSettings.shared.sidebarPerWorkspaceState = true
        defer { AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        let width: CGFloat = 301.5
        if !windowController.sidebarVisible {
            windowController.toggleSidebar(userInitiated: true)
        }

        let firstPosition = dividerPosition(forSidebarWidth: width, in: windowController)
        windowController.mainSplitView.setPosition(firstPosition, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()

        windowController.openWorkspace(path: "/tmp/boo-sidebar-per-workspace-a")
        guard let secondWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected second workspace")
            return
        }
        XCTAssertEqual(secondWorkspace.sidebarState.width ?? -1, width, accuracy: 0.001)
        XCTAssertEqual(sidebarWidth(for: windowController), width, accuracy: 1)

        let adjustedWidth: CGFloat = 333.5
        let secondPosition = dividerPosition(forSidebarWidth: adjustedWidth, in: windowController)
        windowController.mainSplitView.setPosition(secondPosition, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()

        windowController.openWorkspace(path: "/tmp/boo-sidebar-per-workspace-b")
        guard let thirdWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected third workspace")
            return
        }
        XCTAssertEqual(thirdWorkspace.sidebarState.width ?? -1, adjustedWidth, accuracy: 0.001)
        XCTAssertEqual(sidebarWidth(for: windowController), adjustedWidth, accuracy: 1)
    }

    func testWorkspaceSwitchUsesGlobalSidebarStateWhenPerWorkspaceDisabled() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        let originalWidth = AppSettings.shared.sidebarWidth
        let originalHidden = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarPerWorkspaceState = false
        AppSettings.shared.sidebarWidth = 292
        AppSettings.shared.sidebarDefaultHidden = false
        defer {
            AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace
            AppSettings.shared.sidebarWidth = originalWidth
            AppSettings.shared.sidebarDefaultHidden = originalHidden
        }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }

        firstWorkspace.sidebarState = SidebarWorkspaceState(isVisible: true, width: 201)
        windowController.openWorkspace(path: "/tmp/boo-sidebar-global-workspace-b")

        guard let secondWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected a second workspace")
            return
        }

        secondWorkspace.sidebarState = SidebarWorkspaceState(isVisible: false, width: 366)

        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), 292, accuracy: 1)

        let newWidth: CGFloat = 318.5
        let position = dividerPosition(forSidebarWidth: newWidth, in: windowController)
        windowController.mainSplitView.setPosition(position, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()
        let expectedWidth = AppSettings.shared.sidebarWidth

        windowController.activateWorkspace(0)

        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 1)
        XCTAssertEqual(AppSettings.shared.sidebarWidth, expectedWidth, accuracy: 0.001)

        windowController.activateWorkspace(1)

        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 1)
    }

    func testGlobalSidebarResizePersistenceDoesNotReenterLayoutRefresh() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        let originalWidth = AppSettings.shared.sidebarWidth
        let originalHidden = AppSettings.shared.sidebarDefaultHidden
        AppSettings.shared.sidebarPerWorkspaceState = false
        AppSettings.shared.sidebarWidth = 292
        AppSettings.shared.sidebarDefaultHidden = false
        defer {
            AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace
            AppSettings.shared.sidebarWidth = originalWidth
            AppSettings.shared.sidebarDefaultHidden = originalHidden
        }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        let requestedWidth: CGFloat = 318.5
        let position = dividerPosition(forSidebarWidth: requestedWidth, in: windowController)
        windowController.mainSplitView.setPosition(position, ofDividerAt: 0)
        windowController.sidebarController.syncWorkspaceSidebarState()

        let expectedWidth = AppSettings.shared.sidebarWidth
        XCTAssertFalse(windowController.isIgnoringSidebarLayoutSettingsRefresh)
        XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 1)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(windowController.isIgnoringSidebarLayoutSettingsRefresh)
        XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 1)
    }

    func testRepeatedWorkspaceSwitchesDoNotShrinkSidebarWidth() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let originalPerWorkspace = AppSettings.shared.sidebarPerWorkspaceState
        let originalPosition = AppSettings.shared.sidebarPosition
        AppSettings.shared.sidebarPerWorkspaceState = true
        AppSettings.shared.sidebarPosition = .right
        defer {
            AppSettings.shared.sidebarPerWorkspaceState = originalPerWorkspace
            AppSettings.shared.sidebarPosition = originalPosition
        }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected an initial workspace")
            return
        }

        let requestedWidth: CGFloat = 312.5
        firstWorkspace.sidebarState = SidebarWorkspaceState(isVisible: true, width: requestedWidth)
        windowController.activateWorkspace(0)
        let expectedWidth = firstWorkspace.sidebarState.width ?? requestedWidth

        XCTAssertEqual(windowController.currentSidebarPosition, .right)
        XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 0.001)

        windowController.openWorkspace(path: "/tmp/boo-sidebar-switch-loop")
        guard let secondWorkspace = windowController.activeWorkspace else {
            XCTFail("Expected a second workspace")
            return
        }
        secondWorkspace.sidebarState = SidebarWorkspaceState(isVisible: true, width: expectedWidth)
        windowController.activateWorkspace(1)

        for _ in 0..<10 {
            windowController.activateWorkspace(0)
            XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 0.001)
            XCTAssertEqual(firstWorkspace.sidebarState.width ?? -1, expectedWidth, accuracy: 0.001)

            windowController.activateWorkspace(1)
            XCTAssertEqual(sidebarWidth(for: windowController), expectedWidth, accuracy: 0.001)
            XCTAssertEqual(secondWorkspace.sidebarState.width ?? -1, expectedWidth, accuracy: 0.001)
        }
    }
}
