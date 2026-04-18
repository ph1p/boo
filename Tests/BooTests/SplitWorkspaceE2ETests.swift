import Combine
import XCTest

@testable import Boo

/// End-to-end tests for split pane operations, workspace lifecycle, tab management,
/// and keyboard-triggered actions. Uses DebugPlugin as an event recorder to verify
/// the full pipeline: user action → model mutation → bridge event → plugin notification.
@MainActor
final class SplitWorkspaceE2ETests: XCTestCase {

    private var bridge: TerminalBridge!
    private var registry: PluginRegistry!
    private var debug: DebugPlugin!
    private var cancellables: Set<AnyCancellable>!
    private let paneID = UUID()
    private let workspaceID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        cancellables = []
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        registry = PluginRegistry()
        debug = DebugPlugin()
        registry.register(debug)

        bridge.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let ctx = self.makeContext()
                    switch event {
                    case .directoryChanged(let path):
                        self.registry.notifyCwdChanged(newPath: path, context: ctx)
                        self.registry.runCycle(baseContext: ctx, reason: .cwdChanged)
                    case .processChanged(let name):
                        self.registry.notifyProcessChanged(name: name, context: ctx)
                        self.registry.runCycle(baseContext: ctx, reason: .processChanged)
                    case .remoteSessionChanged(let session):
                        self.registry.notifyRemoteSessionChanged(session: session, context: ctx)
                        self.registry.runCycle(baseContext: ctx, reason: .remoteSessionChanged)
                    case .titleChanged:
                        self.registry.runCycle(baseContext: ctx, reason: .titleChanged)
                    case .focusChanged:
                        break
                    default:
                        break
                    }
                }
            }
            .store(in: &cancellables)
    }

    override func tearDown() async throws {
        cancellables = nil
        bridge = nil
        registry = nil
        debug = nil
        try await super.tearDown()
    }

    private func makeContext(
        ws: Workspace? = nil, pane: Pane? = nil
    ) -> TerminalContext {
        let cwd = pane?.activeTab?.workingDirectory ?? bridge.state.workingDirectory
        let process = pane?.activeTab?.state.foregroundProcess ?? bridge.state.foregroundProcess
        return TerminalContext(
            terminalID: bridge.state.tabID,
            cwd: cwd,
            remoteSession: bridge.state.remoteSession,
            gitContext: nil,
            processName: process,
            paneCount: ws?.panes.count ?? 1,
            tabCount: pane?.tabs.count ?? 1
        )
    }

    private func events(named name: String) -> [DebugPlugin.LogEntry] {
        debug.entries.filter { $0.event == name }
    }

    // MARK: - Split → Plugin Cycle

    func testSplitPaneTriggersPluginCycle() {
        let ws = Workspace(folderPath: "/projects")
        let originalID = ws.activePaneID
        let newID = ws.splitPane(originalID, direction: .horizontal)

        // Simulate focus switch to new pane (as MainWindowController would)
        let ctx = makeContext(ws: ws, pane: ws.pane(for: newID))
        registry.notifyFocusChanged(terminalID: newID, context: ctx)
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        let focusEvents = events(named: "focusChanged")
        XCTAssertEqual(focusEvents.count, 1)
        XCTAssertTrue(focusEvents[0].detail.contains(newID.uuidString.prefix(8)))

        // Enrich/react should have run
        XCTAssertFalse(events(named: "enrich").isEmpty)
        XCTAssertFalse(events(named: "react").isEmpty)
    }

    func testSplitInheritsCwdInPluginContext() {
        let ws = Workspace(folderPath: "/tmp")
        ws.pane(for: ws.activePaneID)?.updateWorkingDirectory(at: 0, "/Users/dev/project")
        let newID = ws.splitPane(ws.activePaneID, direction: .vertical)

        let ctx = makeContext(ws: ws, pane: ws.pane(for: newID))
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        let enrichEvents = events(named: "enrich")
        XCTAssertFalse(enrichEvents.isEmpty)
        XCTAssertTrue(enrichEvents.last!.detail.contains("/Users/dev/project"))
    }

    func testClosePaneSwitchesFocusAndNotifies() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id2

        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.activePaneID, id1)

        // Notify the plugin system about the focus change
        let ctx = makeContext(ws: ws, pane: ws.pane(for: id1))
        registry.notifyFocusChanged(terminalID: id1, context: ctx)
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        let focusEvents = events(named: "focusChanged")
        XCTAssertEqual(focusEvents.count, 1)
        XCTAssertTrue(focusEvents[0].detail.contains(id1.uuidString.prefix(8)))
    }

    func testMultipleSplitsAllReportedToPlugin() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        // Focus each pane in sequence
        for paneID in [id1, id2, id3] {
            ws.activePaneID = paneID
            let ctx = makeContext(ws: ws, pane: ws.pane(for: paneID))
            registry.notifyFocusChanged(terminalID: paneID, context: ctx)
            registry.runCycle(baseContext: ctx, reason: .focusChanged)
        }

        let focusEvents = events(named: "focusChanged")
        XCTAssertEqual(focusEvents.count, 3)
    }

    // MARK: - Workspace → Plugin Cycle

    func testWorkspaceSwitchNotifiesPlugins() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/project-a")
        let ws2 = Workspace(folderPath: "/project-b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)

        // Switch to ws1
        state.setActiveWorkspace(0)
        let ctx1 = makeContext(ws: ws1, pane: ws1.pane(for: ws1.activePaneID))
        registry.notifyFocusChanged(terminalID: ws1.activePaneID, context: ctx1)
        registry.notifyCwdChanged(newPath: "/project-a", context: ctx1)
        registry.runCycle(baseContext: ctx1, reason: .focusChanged)

        // Switch to ws2
        state.setActiveWorkspace(1)
        let ctx2 = makeContext(ws: ws2, pane: ws2.pane(for: ws2.activePaneID))
        registry.notifyFocusChanged(terminalID: ws2.activePaneID, context: ctx2)
        registry.notifyCwdChanged(newPath: "/project-b", context: ctx2)
        registry.runCycle(baseContext: ctx2, reason: .focusChanged)

        let cwdEvents = events(named: "cwdChanged")
        XCTAssertEqual(cwdEvents.count, 2)
        XCTAssertTrue(cwdEvents[0].detail.contains("/project-a"))
        XCTAssertTrue(cwdEvents[1].detail.contains("/project-b"))
    }

    func testNewWorkspaceTriggersTerminalCreated() {
        let termID = UUID()
        registry.notifyTerminalCreated(terminalID: termID)

        let createEvents = events(named: "terminalCreated")
        XCTAssertEqual(createEvents.count, 1)

        // Close it
        registry.notifyTerminalClosed(terminalID: termID)
        XCTAssertEqual(events(named: "terminalClosed").count, 1)
    }

    func testWorkspaceRemovalDoesNotCrashPlugins() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/a"))
        state.addWorkspace(Workspace(folderPath: "/b"))
        state.addWorkspace(Workspace(folderPath: "/c"))

        state.removeWorkspace(at: 1)
        XCTAssertEqual(state.workspaces.count, 2)

        // Run a plugin cycle with remaining workspace
        let ws = state.activeWorkspace!
        let ctx = makeContext(ws: ws, pane: ws.pane(for: ws.activePaneID))
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        XCTAssertFalse(events(named: "enrich").isEmpty)
    }

    func testWorkspacePinDoesNotAffectPlugins() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/pinned"))
        state.togglePin(at: 0)
        XCTAssertTrue(state.workspaces[0].isPinned)

        let ws = state.activeWorkspace!
        let ctx = makeContext(ws: ws, pane: ws.pane(for: ws.activePaneID))
        registry.runCycle(baseContext: ctx, reason: .focusChanged)
        XCTAssertFalse(events(named: "enrich").isEmpty)
    }

    // MARK: - Tab Operations → Plugin Cycle

    func testNewTabTriggersPluginCycle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/first")
        _ = pane.addTab(workingDirectory: "/second")

        // Simulate the focus to new tab
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: pane.activeTab!.workingDirectory,
            remoteSession: nil, gitContext: nil,
            processName: "", paneCount: 1,
            tabCount: pane.tabs.count
        )
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        let enrichEvents = events(named: "enrich")
        XCTAssertFalse(enrichEvents.isEmpty)
        XCTAssertTrue(enrichEvents.last!.detail.contains("/second"))
        XCTAssertTrue(enrichEvents.last!.detail.contains("tabs=2"))
    }

    func testCloseTabReportsUpdatedCount() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.removeTab(at: 1)

        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: pane.activeTab!.workingDirectory,
            remoteSession: nil, gitContext: nil,
            processName: "", paneCount: 1,
            tabCount: pane.tabs.count
        )
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        let enrichEvents = events(named: "enrich")
        XCTAssertTrue(enrichEvents.last!.detail.contains("tabs=2"))
    }

    func testTabMovePreservesState() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")
        pane.setActiveTab(0)

        pane.moveTab(from: 0, to: 2)
        // /a moved to position 2, /b and /c shifted left
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/b")
        XCTAssertEqual(pane.tabs[1].workingDirectory, "/c")
        XCTAssertEqual(pane.tabs[2].workingDirectory, "/a")
    }

    func testExtractAndInsertTab() {
        let source = Pane()
        _ = source.addTab(workingDirectory: "/src-a")
        _ = source.addTab(workingDirectory: "/src-b")

        let dest = Pane()
        _ = dest.addTab(workingDirectory: "/dst")

        // Extract tab from source
        let extracted = source.extractTab(at: 0)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(source.tabs.count, 1)

        // Insert into dest
        dest.insertTab(extracted!, at: 1)
        XCTAssertEqual(dest.tabs.count, 2)
        XCTAssertEqual(dest.tabs[1].workingDirectory, "/src-a")
        XCTAssertEqual(dest.activeTabIndex, 1)  // inserted tab becomes active
    }

    // MARK: - Focus Cycling (Cmd+] / Cmd+[)

    func testFocusCycleForward() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        _ = ws.splitPane(id2, direction: .vertical)  // id3 needed to make 3 leaves
        ws.activePaneID = id1

        let leafIDs = ws.splitTree.leafIDs
        XCTAssertEqual(leafIDs.count, 3)

        // Simulate Cmd+] — cycle forward through leafIDs
        let currentIdx = leafIDs.firstIndex(of: ws.activePaneID)!
        let nextIdx = (currentIdx + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx]

        XCTAssertEqual(ws.activePaneID, id2)

        // Notify plugin
        let ctx = makeContext(ws: ws, pane: ws.pane(for: ws.activePaneID))
        registry.notifyFocusChanged(terminalID: ws.activePaneID, context: ctx)

        let focusEvents = events(named: "focusChanged")
        XCTAssertEqual(focusEvents.count, 1)
        XCTAssertTrue(focusEvents[0].detail.contains(id2.uuidString.prefix(8)))
    }

    func testFocusCycleBackward() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)
        ws.activePaneID = id1

        let leafIDs = ws.splitTree.leafIDs

        // Simulate Cmd+[ — cycle backward
        let currentIdx = leafIDs.firstIndex(of: ws.activePaneID)!
        let prevIdx = (currentIdx - 1 + leafIDs.count) % leafIDs.count
        ws.activePaneID = leafIDs[prevIdx]

        XCTAssertEqual(ws.activePaneID, id3, "Backward from first wraps to last")
    }

    func testFocusCycleWrapsAround() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id2

        let leafIDs = ws.splitTree.leafIDs

        // Forward from last wraps to first
        let currentIdx = leafIDs.firstIndex(of: ws.activePaneID)!
        let nextIdx = (currentIdx + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx]

        XCTAssertEqual(ws.activePaneID, id1)
    }

    // MARK: - Smart Close (Cmd+W)

    func testSmartCloseMultipleTabs() {
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        _ = pane.addTab(workingDirectory: "/b")
        XCTAssertEqual(pane.tabs.count, 2)

        // Smart close: multiple tabs → close active tab
        pane.removeTab(at: pane.activeTabIndex)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(ws.panes.count, 1, "Pane still exists")
    }

    func testSmartCloseSingleTabMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id2

        // Smart close: single tab, multiple panes → close pane
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.activePaneID, id1)
    }

    func testSmartCloseLastPaneMultipleWorkspaces() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.setActiveWorkspace(1)

        // Smart close: last pane, multiple workspaces → close workspace
        state.removeWorkspace(at: 1)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)
    }

    // MARK: - Equalize Splits (Cmd+Ctrl+=)

    func testEqualizeSplitsNotifiesPlugins() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        _ = ws.splitPane(id1, direction: .horizontal)
        ws.equalizeSplits()

        if case .split(_, _, _, let ratio) = ws.splitTree {
            XCTAssertEqual(ratio, 0.5)
        } else {
            XCTFail("Expected split tree")
        }

        // Run cycle after equalize
        let ctx = makeContext(ws: ws, pane: ws.pane(for: ws.activePaneID))
        registry.runCycle(baseContext: ctx, reason: .focusChanged)
        XCTAssertFalse(events(named: "enrich").isEmpty)
    }

    func testEqualizeNestedSplits() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        _ = ws.splitPane(id2, direction: .vertical)

        ws.equalizeSplits()

        // Verify all ratios are 0.5
        func checkRatios(_ tree: SplitTree) {
            if case .split(_, let first, let second, let ratio) = tree {
                XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
                checkRatios(first)
                checkRatios(second)
            }
        }
        checkRatios(ws.splitTree)
    }

    // MARK: - Workspace Switching (Cmd+1..9)

    func testSwitchWorkspaceByIndex() {
        let state = AppState()
        for i in 1...5 {
            state.addWorkspace(Workspace(folderPath: "/ws\(i)"))
        }

        // Cmd+1 → workspace 0
        state.setActiveWorkspace(0)
        XCTAssertEqual(state.activeWorkspace?.folderPath, "/ws1")

        // Cmd+3 → workspace 2
        state.setActiveWorkspace(2)
        XCTAssertEqual(state.activeWorkspace?.folderPath, "/ws3")

        // Cmd+5 → workspace 4
        state.setActiveWorkspace(4)
        XCTAssertEqual(state.activeWorkspace?.folderPath, "/ws5")
    }

    func testSwitchToNonExistentWorkspaceIgnored() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/only"))
        state.setActiveWorkspace(0)

        // Cmd+9 — out of bounds
        state.setActiveWorkspace(8)
        XCTAssertEqual(state.activeWorkspaceIndex, 0, "Should stay at current workspace")
    }

    // MARK: - Split Direction (Cmd+D / Cmd+Shift+D)

    func testSplitHorizontal() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        if case .split(let dir, _, _, _) = ws.splitTree {
            XCTAssertEqual(dir, .horizontal)
        } else {
            XCTFail("Expected horizontal split")
        }
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id2))
    }

    func testSplitVertical() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let newID = ws.splitPane(id1, direction: .vertical)

        if case .split(let dir, _, _, _) = ws.splitTree {
            XCTAssertEqual(dir, .vertical)
        } else {
            XCTFail("Expected vertical split")
        }
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(newID))
    }

    // MARK: - New Tab (Cmd+T)

    func testNewTabInheritsCwd() {
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.updateWorkingDirectory(at: 0, "/current/project")

        let cwd = pane.activeTab?.workingDirectory ?? "/tmp"
        _ = pane.addTab(workingDirectory: cwd)

        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTab?.workingDirectory, "/current/project")
    }

    // MARK: - Full Keyboard Scenario

    /// Simulates a realistic keyboard-driven session:
    /// New workspace → split → focus cycle → new tab → close tab → close pane → close workspace
    func testFullKeyboardDrivenSession() {
        let state = AppState()

        // Cmd+N: New workspace
        let ws = Workspace(folderPath: "/home/dev")
        state.addWorkspace(ws)
        XCTAssertEqual(state.workspaces.count, 1)
        registry.notifyTerminalCreated(terminalID: ws.activePaneID)

        // Cmd+D: Split right
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        XCTAssertEqual(ws.panes.count, 2)

        // Cmd+Shift+D: Split down on the new pane
        let id3 = ws.splitPane(id2, direction: .vertical)
        XCTAssertEqual(ws.panes.count, 3)

        // Cmd+]: Focus next (id2 → id3)
        ws.activePaneID = id2
        let leafIDs = ws.splitTree.leafIDs
        let nextIdx = (leafIDs.firstIndex(of: id2)! + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx]
        XCTAssertEqual(ws.activePaneID, id3)

        // Cmd+T: New tab in focused pane
        let pane3 = ws.pane(for: id3)!
        _ = pane3.addTab(workingDirectory: "/home/dev/docs")
        XCTAssertEqual(pane3.tabs.count, 2)

        // Notify plugin of focus change
        let ctx = makeContext(ws: ws, pane: pane3)
        registry.notifyFocusChanged(terminalID: id3, context: ctx)
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        // Cmd+W: Close active tab (2 tabs → 1 tab)
        pane3.removeTab(at: pane3.activeTabIndex)
        XCTAssertEqual(pane3.tabs.count, 1)

        // Cmd+W: Close pane (1 tab, multiple panes)
        ws.activePaneID = id3
        XCTAssertTrue(ws.closePane(id3))
        XCTAssertEqual(ws.panes.count, 2)

        // Cmd+W: Close another pane
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.activePaneID, id1)

        // Verify plugin received events throughout
        XCTAssertFalse(events(named: "terminalCreated").isEmpty)
        XCTAssertFalse(events(named: "focusChanged").isEmpty)
        XCTAssertFalse(events(named: "enrich").isEmpty)
    }

    // MARK: - New Workspace (Cmd+N)

    func testNewWorkspaceActivated() {
        let state = AppState()
        let ws1 = Workspace(folderPath: "/a")
        state.addWorkspace(ws1)
        XCTAssertEqual(state.activeWorkspaceIndex, 0)

        let ws2 = Workspace(folderPath: "/b")
        state.addWorkspace(ws2)
        XCTAssertEqual(state.activeWorkspaceIndex, 1, "New workspace should be active")
        XCTAssertTrue(state.activeWorkspace === ws2)
    }

    func testNewWorkspaceSinglePane() {
        let ws = Workspace(folderPath: "/home/user")
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 1)
        XCTAssertEqual(ws.pane(for: ws.activePaneID)?.activeTab?.workingDirectory, "/home/user")
    }

    // MARK: - Tab Reorder via Drag

    func testMoveTabForward() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")

        pane.moveTab(from: 0, to: 2)
        XCTAssertEqual(pane.tabs.map(\.workingDirectory), ["/b", "/c", "/a"])
    }

    func testMoveTabBackward() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        _ = pane.addTab(workingDirectory: "/c")

        pane.moveTab(from: 2, to: 0)
        XCTAssertEqual(pane.tabs.map(\.workingDirectory), ["/c", "/a", "/b"])
    }

    func testMoveTabSameIndexNoOp() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        pane.moveTab(from: 1, to: 1)
        XCTAssertEqual(pane.tabs.map(\.workingDirectory), ["/a", "/b"])
    }

    // MARK: - Process State in Split Panes

    func testProcessChangeInSplitPaneIsolated() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        // Update process in pane 1 only
        ws.pane(for: id1)?.updateForegroundProcess(at: 0, "vim")

        XCTAssertEqual(ws.pane(for: id1)?.activeTab?.state.foregroundProcess, "vim")
        XCTAssertEqual(ws.pane(for: id2)?.activeTab?.state.foregroundProcess, "")
    }

    // MARK: - Remote Session in Workspace Context

    func testRemoteSessionInSplitPaneNotifiesPlugin() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        _ = ws.splitPane(id1, direction: .horizontal)

        // Simulate SSH in pane 1 — notify plugin directly (sink is async via RunLoop.main)
        let session = RemoteSessionType.ssh(host: "prod.example.com")
        let ctx = makeContext(ws: ws, pane: ws.pane(for: id1))
        registry.notifyRemoteSessionChanged(session: session, context: ctx)
        registry.runCycle(baseContext: ctx, reason: .remoteSessionChanged)

        let remoteEvents = events(named: "remoteSessionChanged")
        XCTAssertGreaterThanOrEqual(remoteEvents.count, 1)
    }

    // MARK: - SplitTree Swap Children

    func testSwapChildrenAtParent() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        // Before swap: id1 is first, id2 is second
        XCTAssertEqual(splitTree.leafIDs, [id1, id2])

        let swapped = splitTree.swappingChildrenAtParent(of: id1)
        XCTAssertEqual(swapped.leafIDs, [id2, id1])
    }
}
