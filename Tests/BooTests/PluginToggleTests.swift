import XCTest

@testable import Boo

/// Tests that toggling plugins via sidebar icons only affects per-tab state,
/// not the global defaultEnabledPluginIDs setting.
@MainActor
final class PluginToggleTests: XCTestCase {

    // MARK: - Toggle does not affect global defaults

    func testToggleOffDoesNotChangeGlobalDefaults() {
        let originalDefaults = AppSettings.shared.defaultEnabledPluginIDs

        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        // Simulate toggling off a plugin (same as togglePluginInSidebar)
        var open = pane.activeTab!.state.openPluginIDs
        open.remove("git-panel")
        pane.updatePluginState(at: 0, open: open, expanded: pane.activeTab!.state.expandedPluginIDs)

        XCTAssertFalse(
            pane.activeTab!.state.openPluginIDs.contains("git-panel"),
            "Plugin should be removed from tab state")
        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, originalDefaults,
            "Global defaults should NOT change when toggling a plugin in the sidebar")
    }

    func testToggleOnDoesNotChangeGlobalDefaults() {
        let originalDefaults = AppSettings.shared.defaultEnabledPluginIDs

        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        // Start with minimal open set
        pane.updatePluginState(at: 0, open: ["file-tree-local"], expanded: ["file-tree-local"])

        // Simulate toggling on a plugin
        var open = pane.activeTab!.state.openPluginIDs
        open.insert("bookmarks")
        pane.updatePluginState(at: 0, open: open, expanded: pane.activeTab!.state.expandedPluginIDs)

        XCTAssertTrue(
            pane.activeTab!.state.openPluginIDs.contains("bookmarks"),
            "Plugin should be added to tab state")
        XCTAssertEqual(
            AppSettings.shared.defaultEnabledPluginIDs, originalDefaults,
            "Global defaults should NOT change when toggling a plugin in the sidebar")
    }

    // MARK: - Per-tab state isolation

    func testToggleInOneTabDoesNotAffectOtherTab() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp/a")
        _ = pane.addTab(workingDirectory: "/tmp/b")

        let defaultOpen = pane.tabs[0].state.openPluginIDs

        // Toggle off git-panel in tab 0
        var open0 = pane.tabs[0].state.openPluginIDs
        open0.remove("git-panel")
        pane.updatePluginState(at: 0, open: open0, expanded: pane.tabs[0].state.expandedPluginIDs)

        XCTAssertFalse(pane.tabs[0].state.openPluginIDs.contains("git-panel"))
        XCTAssertEqual(
            pane.tabs[1].state.openPluginIDs, defaultOpen,
            "Other tab should not be affected by toggle in tab 0")
    }

    // MARK: - New tabs get global defaults

    func testNewTabGetsGlobalDefaults() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")

        let defaults = Set(AppSettings.shared.defaultEnabledPluginIDs)
        let tabOpen = pane.activeTab!.state.openPluginIDs

        XCTAssertEqual(tabOpen, defaults, "New tab should start with global default plugin IDs")
    }
}
