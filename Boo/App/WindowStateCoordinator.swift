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

    /// Per-plugin expanded section IDs (working copy, saved/restored on tab switch).
    var expandedPluginIDs: Set<String> = []
    /// Section IDs the user has explicitly collapsed — suppresses auto-expand on first show.
    var userCollapsedSectionIDs: Set<String> = []
    var sidebarSectionHeights: [String: CGFloat] = [:]
    var sidebarScrollOffsets: [String: CGPoint] = [:]
    var sidebarSectionOrder: [String: [String]] = [:]
    /// The plugin tab the user last selected for this terminal tab.
    var selectedPluginTabID: String? = nil

    init(bridge: TerminalBridge, pluginRegistry: PluginRegistry) {
        self.bridge = bridge
        self.pluginRegistry = pluginRegistry

        // Restore persisted sidebar state from Settings
        loadSidebarStateFromSettings()
    }

    // MARK: - Sidebar State Persistence

    /// Load sidebar heights and order from AppSettings on startup.
    func loadSidebarStateFromSettings() {
        sidebarSectionHeights = AppSettings.shared.sidebarSectionHeights
        sidebarSectionOrder = AppSettings.shared.sidebarSectionOrder
        if AppSettings.shared.sidebarGlobalState {
            expandedPluginIDs = AppSettings.shared.sidebarGlobalExpandedSectionIDs
            userCollapsedSectionIDs = AppSettings.shared.sidebarGlobalUserCollapsedSectionIDs
            selectedPluginTabID = AppSettings.shared.sidebarGlobalSelectedPluginTabID
            sidebarScrollOffsets = AppSettings.shared.sidebarGlobalScrollOffsets
        }
    }

    /// Save current sidebar heights and order to AppSettings.
    /// Call on resize end, panel switch, and app quit.
    func saveSidebarStateToSettings() {
        AppSettings.shared.saveSidebarState(
            heights: sidebarSectionHeights,
            order: sidebarSectionOrder,
            globalExpandedSectionIDs: AppSettings.shared.sidebarGlobalState ? expandedPluginIDs : nil,
            globalUserCollapsedSectionIDs: AppSettings.shared.sidebarGlobalState ? userCollapsedSectionIDs : nil,
            globalSelectedPluginTabID: AppSettings.shared.sidebarGlobalState ? selectedPluginTabID : nil,
            globalScrollOffsets: AppSettings.shared.sidebarGlobalState ? sidebarScrollOffsets : nil
        )
    }

    // MARK: - Tab State Management

    /// Save the current plugin UI state to the given tab.
    /// No-op when sidebar global state is enabled (sidebar is independent of tabs).
    func savePluginState(to pane: Pane, tabIndex: Int) {
        guard !AppSettings.shared.sidebarGlobalState else { return }
        pane.updatePluginState(
            at: tabIndex,
            expanded: expandedPluginIDs,
            userCollapsed: userCollapsedSectionIDs,
            sidebarSectionHeights: sidebarSectionHeights,
            sidebarScrollOffsets: sidebarScrollOffsets,
            sidebarSectionOrder: sidebarSectionOrder,
            selectedPluginTabID: selectedPluginTabID
        )
    }

    /// Restore plugin UI state from a tab.
    /// No-op when sidebar global state is enabled (sidebar is independent of tabs).
    func restorePluginState(from tab: Pane.Tab) {
        guard !AppSettings.shared.sidebarGlobalState else { return }
        expandedPluginIDs = tab.state.expandedPluginIDs
        userCollapsedSectionIDs = tab.state.userCollapsedSectionIDs
        sidebarSectionHeights = tab.state.sidebarSectionHeights
        sidebarScrollOffsets = tab.state.sidebarScrollOffsets
        sidebarSectionOrder = tab.state.sidebarSectionOrder
        selectedPluginTabID = tab.state.selectedPluginTabID
    }

    /// Handle a tab switch: save previous tab's state, restore new tab's state,
    /// and update the bridge to reflect the new tab.
    func activateTab(_ tab: Pane.Tab, paneID: UUID, previousTabPaneResolver: (UUID) -> Pane?) {
        // Save current plugin state and bridge state to previous tab
        if let prevTabID = previousFocusedTabID,
            let prevPane = previousTabPaneResolver(prevTabID)
        {
            if let tabIdx = prevPane.tabs.firstIndex(where: { $0.id == prevTabID }) {
                // Sync live bridge state to the outgoing tab before saving
                syncBridgeToTab(pane: prevPane, tabIndex: tabIdx)
                savePluginState(to: prevPane, tabIndex: tabIdx)
            }
        }

        // Restore from new tab
        restorePluginState(from: tab)
        previousFocusedTabID = tab.id

        // Update bridge to reflect the new active tab
        bridge.restoreTabState(
            paneID: paneID,
            tabID: tab.id,
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
        pane.updateForegroundProcess(at: tabIndex, bridge.state.foregroundProcess)
        remoteLog(
            "[Coordinator] syncBridgeToTab: idx=\(tabIndex) remoteCwd=\(bridge.state.remoteCwd ?? "nil") session=\(bridge.state.remoteSession?.envType ?? "nil") process=\(bridge.state.foregroundProcess) title=\(bridge.state.terminalTitle.prefix(40))"
        )
    }

    /// Build a TerminalContext from the active tab's state.
    /// Bridge state is the single source of truth for the focused pane's remote
    /// session and CWD — never fall back to tab state which may be stale.
    func buildContext(
        paneID: UUID,
        tabID: UUID? = nil,
        tabState: TabState,
        gitContext: TerminalContext.GitContext?,
        processName: String,
        paneCount: Int,
        tabCount: Int
    ) -> TerminalContext {
        // For the active pane, bridge is authoritative. For inactive panes
        // (paneID doesn't match bridge), fall back to tab state.
        let isActivePaneBridge = paneID == bridge.state.paneID
        let remoteSession = isActivePaneBridge ? bridge.state.remoteSession : tabState.remoteSession
        let remoteCwd = isActivePaneBridge ? bridge.state.remoteCwd : tabState.remoteWorkingDirectory
        return TerminalContext(
            terminalID: tabID ?? paneID,
            cwd: tabState.workingDirectory,
            remoteSession: remoteSession,
            remoteCwd: remoteCwd,
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
