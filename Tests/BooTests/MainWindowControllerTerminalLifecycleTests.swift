import XCTest

@testable import Boo

@MainActor
final class MainWindowControllerTerminalLifecycleTests: XCTestCase {

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
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Requires a display (NSWindow)")
        let windowController = MainWindowController()
        let spy = TerminalCloseSpyPlugin()
        windowController.pluginRegistry.register(spy)

        guard let workspace = windowController.activeWorkspace,
            let pane = workspace.pane(for: workspace.activePaneID),
            let firstTabID = pane.activeTab?.id
        else {
            XCTFail("Expected an initial workspace with one pane and one tab")
            return
        }

        _ = pane.addTab(workingDirectory: "/tmp/extra-tab")
        let secondTabID = pane.activeTab?.id

        windowController.forceCloseWorkspace(at: 0)

        XCTAssertEqual(
            Set(spy.closedTerminalIDs),
            Set([firstTabID, secondTabID].compactMap { $0 }),
            "Closing a workspace should emit terminalClosed for every tab it owns"
        )
    }

    func testProcessChangeRefreshesStatusBarAfterPluginCycle() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Requires a display (NSWindow)")
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
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Requires a display (NSWindow)")
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
            open: ["file-tree-local", "bookmarks"],
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

    func testWorkspaceSwitchSavesAndRestoresSidebarPanelState() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Requires a display (NSWindow)")
        let windowController = MainWindowController()
        defer { windowController.window?.close() }

        guard let firstWorkspace = windowController.activeWorkspace,
            let firstTab = firstWorkspace.pane(for: firstWorkspace.activePaneID)?.activeTab
        else {
            XCTFail("Expected an initial workspace")
            return
        }

        windowController.pluginSidebarPanelView?.removeFromSuperview()
        windowController.pluginSidebarPanelView = nil

        let firstOpen: Set<String> = ["file-tree-local", "bookmarks"]
        let firstExpanded: Set<String> = ["file-tree-local", "bookmarks"]
        let firstHeights: [String: CGFloat] = ["bookmarks": 196]
        let firstOffsets: [String: CGPoint] = [
            "\(firstTab.id.uuidString):bookmarks": CGPoint(x: 0, y: 44)
        ]

        windowController.openPluginIDs = firstOpen
        windowController.expandedPluginIDs = firstExpanded
        windowController.savedSidebarHeights = firstHeights
        windowController.savedSidebarScrollOffsets = firstOffsets

        windowController.openWorkspace(path: "/tmp/boo-sidebar-state")

        XCTAssertEqual(
            firstWorkspace.pane(for: firstWorkspace.activePaneID)?.activeTab?.state.openPluginIDs,
            firstOpen
        )
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

        let secondOpen: Set<String> = ["file-tree-local", "git-panel"]
        let secondExpanded: Set<String> = ["file-tree-local", "git-panel"]
        let secondHeights: [String: CGFloat] = ["git-panel": 155]
        let secondOffsets: [String: CGPoint] = [
            "\(secondTab.id.uuidString):git-panel": CGPoint(x: 0, y: 28)
        ]

        windowController.pluginSidebarPanelView?.removeFromSuperview()
        windowController.pluginSidebarPanelView = nil
        windowController.openPluginIDs = secondOpen
        windowController.expandedPluginIDs = secondExpanded
        windowController.savedSidebarHeights = secondHeights
        windowController.savedSidebarScrollOffsets = secondOffsets

        windowController.activateWorkspace(0)

        XCTAssertEqual(windowController.openPluginIDs, firstOpen)
        XCTAssertEqual(windowController.expandedPluginIDs, firstExpanded)
        XCTAssertEqual(windowController.savedSidebarHeights, firstHeights)
        XCTAssertEqual(
            windowController.savedSidebarScrollOffsets["\(firstTab.id.uuidString):bookmarks"]?.y ?? -1,
            44,
            accuracy: 0.1
        )
        XCTAssertEqual(windowController.previousFocusedTabID, firstTab.id)
    }
}
