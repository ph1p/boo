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

    // MARK: - Tab Operations → Plugin Cycle

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

    // MARK: - Smart Close (Cmd+W)

    func testSmartCloseSingleTabMultiplePanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
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
        let id2 = ws.splitPane(id1, direction: .horizontal)!

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
        let newID = ws.splitPane(id1, direction: .vertical)!

        if case .split(let dir, _, _, _) = ws.splitTree {
            XCTAssertEqual(dir, .vertical)
        } else {
            XCTFail("Expected vertical split")
        }
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(newID))
    }

    // MARK: - New Workspace (Cmd+Shift+N)

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
        let id2 = ws.splitPane(id1, direction: .horizontal)!

        // Update process in pane 1 only
        ws.pane(for: id1)?.updateForegroundProcess(at: 0, "vim")

        XCTAssertEqual(ws.pane(for: id1)?.activeTab?.state.foregroundProcess, "vim")
        XCTAssertEqual(ws.pane(for: id2)?.activeTab?.state.foregroundProcess, "")
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
