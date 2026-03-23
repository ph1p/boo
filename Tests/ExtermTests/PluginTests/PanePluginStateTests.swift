import XCTest

@testable import Exterm

/// Tests for per-tab sidebar plugin state persistence.
/// Exercises the same state-management logic used by MainWindowController
/// via TabState.openPluginIDs / TabState.expandedPluginIDs on each Pane.Tab.
@MainActor
final class PanePluginStateTests: XCTestCase {

    // MARK: - Toggle persists to TabState

    func testTogglePersistsToActiveTabState() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        var openPluginIDs = pane.activeTab!.state.openPluginIDs

        // Simulate togglePluginInSidebar("bookmarks") — removing it
        openPluginIDs.remove("bookmarks")
        let expandedPluginIDs = pane.activeTab!.state.expandedPluginIDs

        pane.updatePluginState(at: pane.activeTabIndex, open: openPluginIDs, expanded: expandedPluginIDs)

        XCTAssertFalse(
            pane.activeTab!.state.openPluginIDs.contains("bookmarks"),
            "Toggled-off plugin should be removed from tab state")
        XCTAssertTrue(
            pane.activeTab!.state.openPluginIDs.contains("file-tree-local"),
            "Other plugins should remain")
    }

    func testToggleOnPersistsToActiveTabState() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        // Start with only file-tree
        pane.updatePluginState(at: 0, open: ["file-tree-local"], expanded: ["file-tree-local"])

        var open = pane.activeTab!.state.openPluginIDs
        var expanded = pane.activeTab!.state.expandedPluginIDs
        open.insert("bookmarks")
        expanded.insert("bookmarks")

        pane.updatePluginState(at: 0, open: open, expanded: expanded)

        XCTAssertTrue(pane.activeTab!.state.openPluginIDs.contains("bookmarks"))
        XCTAssertTrue(pane.activeTab!.state.expandedPluginIDs.contains("bookmarks"))
    }

    // MARK: - Tab switch saves and restores state

    func testTabSwitchRestoresPerTabState() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        // Tab 0 has custom state: only file-tree open
        pane.updatePluginState(at: 0, open: ["file-tree-local"], expanded: ["file-tree-local"])

        // Tab 1 has all plugins open
        pane.updatePluginState(
            at: 1, open: ["file-tree-local", "git-panel", "docker", "bookmarks"],
            expanded: ["file-tree-local", "bookmarks"])

        // Simulate focusing tab 0 — read its state
        pane.setActiveTab(0)
        var openPluginIDs = pane.activeTab!.state.openPluginIDs
        XCTAssertEqual(openPluginIDs, ["file-tree-local"])

        // Simulate switching to tab 1 — save tab 0, restore tab 1
        pane.updatePluginState(at: 0, open: openPluginIDs, expanded: pane.tabs[0].state.expandedPluginIDs)
        pane.setActiveTab(1)
        openPluginIDs = pane.activeTab!.state.openPluginIDs
        let expandedPluginIDs = pane.activeTab!.state.expandedPluginIDs

        XCTAssertEqual(openPluginIDs, ["file-tree-local", "git-panel", "docker", "bookmarks"])
        XCTAssertEqual(expandedPluginIDs, ["file-tree-local", "bookmarks"])
    }

    // MARK: - New pane's tab inherits parent tab state

    func testNewPaneTabInheritsParentTabState() {
        let parentPane = Pane()
        _ = parentPane.addTab(workingDirectory: "/tmp")
        parentPane.updatePluginState(
            at: 0, open: ["file-tree-local", "bookmarks"],
            expanded: ["file-tree-local", "bookmarks"])

        // Simulate splitActivePane: new pane inherits parent tab's state
        let newPane = Pane()
        _ = newPane.addTab(workingDirectory: "/tmp")
        let parentState = parentPane.activeTab!.state
        newPane.updatePluginState(
            at: 0, open: parentState.openPluginIDs,
            expanded: parentState.expandedPluginIDs)

        XCTAssertEqual(
            newPane.activeTab!.state.openPluginIDs, ["file-tree-local", "bookmarks"],
            "New tab should inherit parent tab's saved state")
        XCTAssertEqual(
            newPane.activeTab!.state.expandedPluginIDs, ["file-tree-local", "bookmarks"],
            "New tab should inherit parent tab's expanded state")
    }

    func testNewPaneTabUsesDefaultsWhenParentHasDefaults() {
        let parentPane = Pane()
        _ = parentPane.addTab(workingDirectory: "/tmp")
        // Parent has default state (not customized)

        let newPane = Pane()
        _ = newPane.addTab(workingDirectory: "/tmp")
        // New tab gets default TabState, same as parent
        let parentState = parentPane.activeTab!.state

        newPane.updatePluginState(
            at: 0, open: parentState.openPluginIDs,
            expanded: parentState.expandedPluginIDs)

        XCTAssertEqual(
            newPane.activeTab!.state.openPluginIDs,
            Set(AppSettings.shared.defaultEnabledPluginIDs),
            "New tab should use defaults when parent has defaults")
    }

    // MARK: - Migration from old file-tree ID

    func testMigratePluginIDsReplacesOldFileTree() {
        let old: Set<String> = ["file-tree", "git-panel", "docker", "bookmarks"]
        let migrated = Pane.migratePluginIDs(old)
        XCTAssertFalse(migrated.contains("file-tree"))
        XCTAssertTrue(migrated.contains("file-tree-local"))
        XCTAssertTrue(migrated.contains("file-tree-remote"))
        XCTAssertTrue(migrated.contains("git-panel"))
    }

    func testMigratePluginIDsLeavesNewIDsAlone() {
        let current: Set<String> = ["file-tree-local", "file-tree-remote", "git-panel"]
        let migrated = Pane.migratePluginIDs(current)
        XCTAssertEqual(migrated, current)
    }

    // MARK: - Context visibility filters correctly

    func testGitPluginHiddenWithoutGitContext() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let noGitContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let result = registry.runCycle(baseContext: noGitContext, reason: .focusChanged)
        XCTAssertFalse(
            result.visiblePluginIDs.contains("git-panel"),
            "Git plugin should be hidden when there is no git context")
    }

    func testGitPluginVisibleWithGitContext() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let gitContext = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: TerminalContext.GitContext(
                branch: "main", repoRoot: "/repo", isDirty: false,
                changedFileCount: 0, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil
            ),
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let result = registry.runCycle(baseContext: gitContext, reason: .focusChanged)
        XCTAssertTrue(
            result.visiblePluginIDs.contains("git-panel"),
            "Git plugin should be visible when git context is present")
    }

    // MARK: - Expand/collapse persists per tab

    func testExpandCollapsePersistsToActiveTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        // Expand bookmarks
        var expanded = pane.activeTab!.state.expandedPluginIDs
        expanded.insert("bookmarks")
        pane.updatePluginState(at: 0, open: pane.activeTab!.state.openPluginIDs, expanded: expanded)

        XCTAssertTrue(
            pane.activeTab!.state.expandedPluginIDs.contains("bookmarks"),
            "Expanded state should be persisted after toggle")

        // Collapse bookmarks
        expanded.remove("bookmarks")
        pane.updatePluginState(at: 0, open: pane.activeTab!.state.openPluginIDs, expanded: expanded)

        XCTAssertFalse(
            pane.activeTab!.state.expandedPluginIDs.contains("bookmarks"),
            "Collapsed state should be persisted after toggle")
    }
}
