import XCTest

@testable import Boo

@MainActor
final class MainWindowControllerTerminalLifecycleTests: XCTestCase {
    private func sidebarWidth(for windowController: MainWindowController) -> CGFloat {
        let sidebarIndex = windowController.currentSidebarPosition == .left ? 0 : 1
        guard sidebarIndex < windowController.mainSplitView.subviews.count else { return 0 }
        return windowController.mainSplitView.subviews[sidebarIndex].frame.width
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

    func testSplitPaneRemapsSidebarScrollOffsetsToNewTerminal() throws {
        // Per-tab sidebar state is only written to tabs when global state is off (the default).
        let settings = AppSettings.shared
        let originalGlobal = settings.sidebarGlobalState
        settings.sidebarGlobalState = false
        defer { settings.sidebarGlobalState = originalGlobal }
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

    func testHidingSidebarPreservesWorkspaceWidth() throws {
        let originalScope = AppSettings.shared.sidebarStateScope
        AppSettings.shared.sidebarStateScope = .workspace
        defer { AppSettings.shared.sidebarStateScope = originalScope }

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

    func testTabScopeKeepsSidebarVisibilityPerTab() throws {
        let originalScope = AppSettings.shared.sidebarStateScope
        AppSettings.shared.sidebarStateScope = .tab
        defer { AppSettings.shared.sidebarStateScope = originalScope }

        let windowController = MainWindowController()
        defer { windowController.window?.close() }
        let workspace = try XCTUnwrap(windowController.activeWorkspace)
        let pane = try XCTUnwrap(workspace.pane(for: workspace.activePaneID))
        windowController.activateWorkspace(0)
        if !windowController.sidebarVisible { windowController.toggleSidebar(userInitiated: true) }
        XCTAssertEqual(pane.tabs[0].state.sidebarVisible, true)

        // A new tab starts with the current state and gets its own on change.
        let second = pane.addTab(workingDirectory: workspace.folderPath)
        pane.setActiveTab(second)
        XCTAssertNil(pane.tabs[second].state.sidebarVisible)
        XCTAssertEqual(windowController.sidebarController.resolveEffectiveSidebarState().isVisible, true)

        windowController.toggleSidebar(userInitiated: true)
        XCTAssertEqual(pane.tabs[second].state.sidebarVisible, false)
        XCTAssertEqual(pane.tabs[0].state.sidebarVisible, true)

        // Back on the first tab the sidebar returns.
        pane.setActiveTab(0)
        windowController.applyFocusedTabSidebarState(in: workspace)
        XCTAssertTrue(windowController.sidebarVisible)
        XCTAssertEqual(pane.tabs[second].state.sidebarVisible, false)
    }

    func testSessionTabRoundTripsSidebarState() throws {
        let data = try JSONEncoder().encode(SessionTab(sidebarVisible: false, sidebarWidth: 301))
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)
        XCTAssertEqual(decoded.sidebarVisible, false)
        XCTAssertEqual(decoded.sidebarWidth, 301)
        XCTAssertNil(try JSONDecoder().decode(SessionTab.self, from: Data("{}".utf8)).sidebarVisible)
    }

}
