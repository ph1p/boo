import Cocoa

// MARK: - Tab group actions

extension MainWindowController {
    func paneView(_ paneView: PaneView, didRequestCloseGroup groupID: UUID, paneID: UUID) {
        guard let workspace = activeWorkspace,
            let pane = workspace.pane(for: paneID),
            let group = pane.group(id: groupID),
            let window
        else { return }
        let members = pane.tabs.filter { $0.groupID == groupID }
        guard !members.isEmpty else { return }
        let ids = members.map(\.id)

        let close = { [weak self, weak paneView] in
            guard let self, let pv = paneView else { return }
            for id in ids {
                guard let index = pane.tabs.firstIndex(where: { $0.id == id }) else { continue }
                if pane.tabs.count == 1 {
                    // The group was the whole pane: close it like its last tab.
                    workspace.activePaneID = paneID
                    self.smartCloseAction(nil)
                    break
                }
                self.closeTab(in: pv, at: index, undo: .live, announce: false)
            }
            DispatchQueue.main.async { AgentInbox.shared.prune() }
        }

        let terminals = members.filter { $0.contentType == .terminal }.count
        let confirmTerminals = {
            guard terminals > 0 else { return close() }
            let alert = NSAlert()
            let name = group.name.isEmpty ? "this group" : "“\(group.name)”"
            alert.messageText =
                members.count == 1 ? "Close the tab in \(name)?" : "Close \(members.count) tabs in \(name)?"
            alert.informativeText =
                terminals == 1 ? "This will end the terminal session." : "This will end \(terminals) terminal sessions."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { close() }
            }
        }

        let unsaved = pane.tabs.indices.lazy
            .filter { pane.tabs[$0].groupID == groupID }
            .compactMap {
                self.unsavedEditorLocation(
                    workspaceIndex: self.appState.activeWorkspaceIndex, paneID: paneID, tabIndex: $0)
            }
            .first
        if let unsaved {
            confirmUnsavedEditorClose(unsaved, proceed: confirmTerminals)
        } else {
            confirmTerminals()
        }
    }

    func paneView(_ paneView: PaneView, didRequestSplitGroup groupID: UUID, paneID: UUID) {
        let activeID = paneView.pane.activeTab?.id
        guard let workspace = activeWorkspace,
            let sourcePane = workspace.pane(for: paneID),
            let originalIndex = sourcePane.tabs.firstIndex(where: { $0.groupID == groupID }),
            // A group holding every tab would just leave an empty pane behind.
            sourcePane.tabs.contains(where: { $0.groupID != groupID }),
            let (group, tabs) = sourcePane.extractGroup(groupID)
        else { return }
        let gvs = tabs.compactMap { tab in
            tab.contentType == .terminal ? paneView.extractGhosttyView(for: tab.id).map { (tab.id, $0) } : nil
        }
        let cvs = tabs.compactMap { tab in
            tab.contentType != .terminal ? paneView.extractContentView(for: tab.id).map { (tab.id, $0) } : nil
        }

        window?.makeFirstResponder(nil)
        guard let newPaneID = workspace.splitPane(paneID, toward: .right, wholeWorkspace: false),
            let newPane = workspace.pane(for: newPaneID)
        else {
            sourcePane.insertGroup(group, tabs: tabs, at: originalIndex)
            for (id, gv) in gvs { paneView.insertGhosttyView(gv, for: id) }
            for (id, cv) in cvs { paneView.insertContentView(cv, for: id) }
            paneView.startActiveSession()
            return
        }

        // Replace the new pane's default tab with the group.
        newPane.stopAll()
        newPane.insertGroup(group, tabs: tabs, at: 0)
        if let active = tabs.firstIndex(where: { $0.id == activeID }) {
            newPane.setActiveTab(active)
        }
        workspace.activePaneID = newPaneID
        paneView.startActiveSession()
        paneView.layoutTerminalView()
        paneView.needsDisplay = true

        updateSplits(workspace.splitTree, fadingIn: newPaneID)
        saveSession()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Hand the live views over before sessions start, so startActiveSession
            // reuses them instead of spawning fresh terminals.
            if let newPV = self.paneViews[newPaneID] {
                for (id, gv) in gvs { newPV.insertGhosttyView(gv, for: id) }
                for (id, cv) in cvs { newPV.insertContentView(cv, for: id) }
            }
            for id in workspace.splitTree.leafIDs {
                if let pv = self.paneViews[id] {
                    pv.tabDragCoordinator = self.tabDragCoordinator
                    pv.startActiveSession()
                }
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
            DispatchQueue.main.async { [weak self] in
                self?.paneViews[newPaneID]?.focusActiveView()
            }
        }
    }
}
