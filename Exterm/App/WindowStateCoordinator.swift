import Combine
import Foundation

/// Centralized state coordinator between TerminalBridge, TabState, and PluginRegistry.
/// Extracts state-management responsibilities from MainWindowController.
@MainActor
final class WindowStateCoordinator {
    let bridge: TerminalBridge
    let pluginRegistry: PluginRegistry

    /// Track the previous tab for saving state on switch.
    var previousFocusedTabID: UUID?

    /// Active plugin UI state (working copy, saved/restored on tab switch).
    var openPluginIDs: Set<String> = ["file-tree-local", "file-tree-remote", "git-panel", "docker", "bookmarks"]
    var expandedPluginIDs: Set<String> = ["file-tree-local", "file-tree-remote"]

    init(bridge: TerminalBridge, pluginRegistry: PluginRegistry) {
        self.bridge = bridge
        self.pluginRegistry = pluginRegistry
    }

    // MARK: - Tab State Management

    /// Save the current plugin UI state to the given tab.
    func savePluginState(to pane: Pane, tabIndex: Int) {
        pane.updatePluginState(at: tabIndex, open: openPluginIDs, expanded: expandedPluginIDs)
    }

    /// Restore plugin UI state from a tab.
    func restorePluginState(from tab: Pane.Tab) {
        openPluginIDs = tab.state.openPluginIDs
        expandedPluginIDs = tab.state.expandedPluginIDs
    }

    /// Handle a tab switch: save previous tab's state, restore new tab's state,
    /// and update the bridge to reflect the new tab.
    func activateTab(_ tab: Pane.Tab, paneID: UUID, previousTabPaneResolver: (UUID) -> Pane?) {
        // Save current plugin state to previous tab
        if let prevTabID = previousFocusedTabID,
           let prevPane = previousTabPaneResolver(prevTabID) {
            if let tabIdx = prevPane.tabs.firstIndex(where: { $0.id == prevTabID }) {
                savePluginState(to: prevPane, tabIndex: tabIdx)
            }
        }

        // Restore from new tab
        restorePluginState(from: tab)
        previousFocusedTabID = tab.id

        // Update bridge to reflect the new active tab
        bridge.restoreTabState(
            paneID: paneID,
            workingDirectory: tab.workingDirectory,
            terminalTitle: tab.title,
            remoteSession: tab.remoteSession,
            remoteCwd: tab.remoteWorkingDirectory,
            shellPID: tab.shellPID
        )
    }

    /// Sync bridge state back to the pane model after a bridge event
    /// (e.g. directory change, title change that triggers remote session detection).
    func syncBridgeToTab(pane: Pane, tabIndex: Int) {
        pane.updateRemoteSession(at: tabIndex, bridge.state.remoteSession)
        pane.updateRemoteWorkingDirectory(at: tabIndex, bridge.state.remoteCwd)
    }

    /// Build a TerminalContext from the active tab's state.
    func buildContext(
        paneID: UUID,
        tabState: TabState,
        gitContext: TerminalContext.GitContext?,
        processName: String,
        paneCount: Int,
        tabCount: Int
    ) -> TerminalContext {
        TerminalContext(
            terminalID: paneID,
            cwd: tabState.workingDirectory,
            remoteSession: tabState.remoteSession,
            remoteCwd: tabState.remoteWorkingDirectory,
            gitContext: gitContext,
            processName: processName,
            paneCount: paneCount,
            tabCount: tabCount
        )
    }

    /// Whether the active tab is in a remote session.
    var isRemote: Bool {
        bridge.state.remoteSession != nil
    }

    /// The active remote session, if any.
    var activeRemoteSession: RemoteSessionType? {
        bridge.state.remoteSession
    }
}
