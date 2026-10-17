import Cocoa
import SwiftUI

/// Timeline tabs, by session ID, so asking again focuses the open one.
@MainActor private var timelineTabs: [String: UUID] = [:]

/// Agent timelines: what a Claude Code session did, read from its transcript.
extension MainWindowController {
    /// Opens the timeline of `sessionID` in the active pane, or focuses the tab
    /// already showing it in this workspace.
    @discardableResult
    func openTimeline(sessionID: String, label: String) -> Bool {
        guard let workspace = activeWorkspace else { return false }
        if let tabID = timelineTabs[sessionID] {
            for pane in workspace.panes.values {
                if let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabID }) {
                    focusActivity(workspaceID: workspace.id, paneID: pane.id, tabIndex: tabIndex)
                    return true
                }
            }
        }
        guard let paneView = paneViews[workspace.activePaneID] else { return false }
        let model = AgentTimelineModel(sessionID: sessionID, label: label, controller: self)
        let tabID = paneView.addPluginViewTab(
            view: AnyView(AgentTimelineView(model: model)), title: "Timeline: \(label)", icon: "clock.arrow.circlepath")
        timelineTabs[sessionID] = tabID
        return tabID != nil
    }

    /// Timeline of the agent in the inbox's `tabID`.
    @discardableResult
    func openTimeline(agentTab tabID: UUID) -> Bool {
        guard let item = AgentInbox.shared.items[tabID], let sessionID = item.sessionID else { return false }
        return openTimeline(sessionID: sessionID, label: AgentHandoff.label(for: item))
    }

    @objc func agentTimelineAction(_ sender: Any?) {
        guard let (sessionID, label) = timelineSessionInActiveWorkspace() else {
            let alert = NSAlert()
            alert.messageText = "No Claude Code session here"
            alert.informativeText =
                "Timelines show what a Claude Code session did. Start Claude Code in a terminal tab of this workspace, then try again."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        openTimeline(sessionID: sessionID, label: label)
    }

    /// The session to show: the active tab's agent, then agents elsewhere in
    /// the workspace (hook-reported first, then those found by process scan).
    func timelineSessionInActiveWorkspace() -> (sessionID: String, label: String)? {
        guard let workspace = activeWorkspace else { return nil }
        let inbox = AgentInbox.shared
        if let tab = workspace.pane(for: workspace.activePaneID)?.activeTab, let item = inbox.items[tab.id],
            let sessionID = item.sessionID
        {
            return (sessionID, AgentHandoff.label(for: item))
        }
        for item in inbox.sortedItems where item.sessionID != nil {
            if inbox.locate(item.tabID)?.workspace.id == workspace.id, let sessionID = item.sessionID {
                return (sessionID, AgentHandoff.label(for: item))
            }
        }
        let sessions = (pluginRegistry.actions?.workspaceAgentSessions?() ?? []).sorted {
            $0.isFocused && !$1.isFocused
        }
        if let session = sessions.first(where: { $0.agent.kind == .claudeCode && $0.agent.sessionID != nil }),
            let sessionID = session.agent.sessionID
        {
            let folder = (session.agent.cwd as NSString).lastPathComponent
            return (
                sessionID, folder.isEmpty ? session.agent.kind.shortName : "\(session.agent.kind.shortName) — \(folder)"
            )
        }
        return nil
    }
}
