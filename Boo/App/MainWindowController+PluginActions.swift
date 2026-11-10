import CGhostty
import Cocoa

// MARK: - Plugin Actions

extension MainWindowController {
    /// Wire the callbacks plugins use to act on this window.
    func installPluginActions() {
        let pluginActions = PluginActions()
        pluginActions.sendToTerminal = { [weak self] in self?.sendRawToActivePane($0) }
        pluginActions.openDirectoryInNewTab = { [weak self] in self?.openDirectoryInNewTab($0) }
        pluginActions.openDirectoryInNewPane = { [weak self] in self?.openDirectoryInNewPane($0) }
        pluginActions.openFileInNewPane = { [weak self] in self?.openFileInNewPane($0) }
        pluginActions.pastePathToActivePane = { [weak self] in self?.pastePathToActivePane($0) }
        pluginActions.isTerminalBusy = { [weak self] in
            guard let self else { return false }
            let process = self.bridge.state.foregroundProcess
            return !process.isEmpty && !ProcessIcon.isShell(process)
        }
        pluginActions.openTab = { [weak self] payload in
            self?.handleOpenTab(payload)
        }
        pluginActions.setAgentSessionID = { [weak self] sessionID in
            guard let self,
                let workspace = self.activeWorkspace,
                let pane = workspace.pane(for: workspace.activePaneID)
            else { return }
            pane.updateAgentSessionID(sessionID)
        }
        pluginActions.getAgentSessionID = { [weak self] in
            guard let self,
                let workspace = self.activeWorkspace,
                let pane = workspace.pane(for: workspace.activePaneID)
            else { return nil }
            return pane.activeTab?.state.agentSessionID
        }
        pluginActions.workspaceAgentSessions = { [weak self] in
            guard let self, let workspace = self.activeWorkspace else { return [] }
            return self.agentSessions(in: workspace)
        }
        pluginActions.activeWorkspaceID = { [weak self] in self?.activeWorkspace?.id }
        pluginActions.focusAgentSession = { [weak self] sessionID in
            guard let self, let workspace = self.activeWorkspace else { return }
            for pane in workspace.panes.values {
                guard let tabIndex = pane.tabs.firstIndex(where: { $0.id == sessionID }) else { continue }
                workspace.activePaneID = pane.id
                if let paneView = self.paneViews[pane.id] {
                    paneView.forceActivateTab(tabIndex)
                } else {
                    pane.setActiveTab(tabIndex)
                    self.runPluginCycle(reason: .focusChanged)
                }
                return
            }
        }
        pluginActions.openAgentTimeline = { [weak self] sessionID, label in
            self?.openTimeline(sessionID: sessionID, label: label)
        }
        pluginActions.displayImageInTerminal = { [weak self] path, newTab in
            guard let self, let workspace = self.activeWorkspace else { return }
            let paneID = workspace.activePaneID
            let activeTabID = workspace.pane(for: paneID)?.activeTab?.id
            let size: ghostty_surface_size_s? = self.ghosttyView(for: paneID)?.surface.map {
                ghostty_surface_size($0)
            }
            func send(tabID: UUID, to shellPID: pid_t) {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let ok = KittyImageProtocol.sendImage(imagePath: path, to: shellPID, terminalSize: size)
                    if !ok {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.pendingImageSends[tabID] = (path, size, shellPID)
                            // zsh may have re-exec'd — refresh from the login process.
                            self.ghosttyView(for: paneID)?.refreshShellPIDIfNeeded(currentPID: shellPID)
                        }
                    }
                }
            }
            if newTab {
                guard let pv = self.paneViews[paneID],
                    let newTabID = pv.addNewTab(workingDirectory: path.deletingLastPathComponent)
                else { return }
                self.refreshStatusBar()
                // Queue keyed by the new tab's ID — isolated from other tabs' retries.
                self.pendingImageSends[newTabID] = (path, size, 0)
            } else {
                guard let tabID = activeTabID else { return }
                guard let shellPID = self.bridge.monitor.shellPID(for: paneID) else {
                    self.pendingImageSends[tabID] = (path, size, 0)
                    return
                }
                send(tabID: tabID, to: shellPID)
            }
        }
        pluginActions.registerMultiContentTab = { [weak self] typeID, factory in
            self?.multiContentTabFactories[typeID] = factory
        }
        pluginActions.openMultiContentTab = { [weak self] typeID, ctx in
            self?.handleOpenMultiContentTab(typeID: typeID, context: ctx)
        }
        pluginRegistry.actions = pluginActions
        bridge.monitor.onShellPIDUpdated = { [weak self] paneID, shellPID, tabID in
            guard let self, let tabID else { return }
            let isNewTab = self.pendingImageSends[tabID]?.failedPID == 0
            if isNewTab {
                // Delay sending until zsh has finished init and printed its first prompt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.flushPendingImageSend(for: tabID, shellPID: shellPID)
                }
            } else {
                self.flushPendingImageSend(for: tabID, shellPID: shellPID)
            }
        }
        pluginRegistry.hostActions = PluginHostActions(
            pastePathToActivePane: { [weak self] in self?.pastePathToActivePane($0) },
            openDirectoryInNewTab: { [weak self] in self?.openDirectoryInNewTab($0) },
            openDirectoryInNewPane: { [weak self] in self?.openDirectoryInNewPane($0) },
            sendRawToActivePane: { [weak self] in self?.sendRawToActivePane($0) },
            setWorkspaceRoot: { [weak self] path in
                guard let self else { return }
                self.appState.activeWorkspace?.folderPath = path
                self.saveSession()
            }
        )
    }
}

extension MainWindowController {
    /// Agents running in the workspace's terminal tabs, found by process
    /// detection (with or without Boo's hooks). Only the active workspace has
    /// a focused tab, whose state the bridge holds live.
    /// The resumable agent in each tab, saved with the session so a crash
    /// doesn't lose the conversation. Empty when agent recovery is off.
    func agentResumePoints() -> [UUID: AgentResumePoint] {
        guard AppSettings.shared.agentRecovery != .off else { return [:] }
        // Agents restored into tabs that haven't started yet: not running, but
        // still owed a resume if Boo goes down again before their tab opens.
        let pending = CrashRecovery.pendingResumePoints
        var points: [UUID: AgentResumePoint] = [:]
        for workspace in appState.workspaces where workspace.tmuxWindowID == nil {
            if !pending.isEmpty {
                for tab in workspace.panes.values.flatMap(\.tabs) { points[tab.id] = pending[tab.id] }
            }
            for session in agentSessions(in: workspace) {
                guard let id = session.agent.sessionID, session.agent.kind != .custom else { continue }
                points[session.tabID] = AgentResumePoint(
                    kind: session.agent.kind, sessionID: id, cwd: session.agent.cwd,
                    wasRunning: session.agent.state == .running)
            }
        }
        return points
    }

    /// Starts the terminals of restored tabs that resume an agent, without
    /// showing them, so agents run again before their tab is opened.
    func startResumedAgents() {
        let pending = CrashRecovery.pendingResumePoints
        guard !pending.isEmpty else { return }
        // Panes of inactive workspaces aren't in the window, so they size from it.
        let size = window?.contentLayoutRect.size ?? NSSize(width: 1000, height: 700)
        for workspace in appState.workspaces where workspace.tmuxWindowID == nil {
            for pane in workspace.panes.values where !pane.tmuxOwned {
                for tab in pane.tabs where pending[tab.id] != nil {
                    // One per runloop turn: each spawns a pty and an agent.
                    DispatchQueue.main.async { [weak self, paneID = pane.id, tabID = tab.id] in
                        self?.paneView(for: paneID, in: workspace)?.startTerminalInBackground(for: tabID, size: size)
                    }
                }
            }
        }
    }

    func agentSessions(in workspace: Workspace) -> [WorkspaceAgentSession] {
        let isActive = workspace.id == activeWorkspace?.id
        let bridge: TerminalBridge = self.bridge
        return workspace.panes.values.flatMap { pane -> [WorkspaceAgentSession] in
            pane.tabs.compactMap { tab in
                // Only terminals run agents. A browser tab has no shell, but while
                // focused the bridge can still carry the previous terminal's agent.
                guard tab.contentType == .terminal else { return nil }
                // The bridge holds the focused tab's live state, but only once it
                // switched to this tab: right after a workspace or tab switch it
                // still describes the previous tab, whose agent would show here.
                let isFocused =
                    isActive && workspace.activePaneID == pane.id && pane.activeTab?.id == tab.id
                    && bridge.state.tabID == tab.id
                var processName = isFocused ? bridge.state.foregroundProcess : tab.state.foregroundProcess
                let processPID = isFocused ? bridge.state.foregroundProcessPID : tab.state.foregroundProcessPID
                var processCategory =
                    isFocused ? bridge.state.foregroundProcessCategory : tab.state.foregroundProcessCategory
                let processMetadata =
                    isFocused ? bridge.state.foregroundProcessMetadata : tab.state.foregroundProcessMetadata
                // For background tabs where process category is unknown, re-resolve via
                // the live process tree so runtimes like node/bun (used by codex) are
                // remapped to their canonical agent name.
                if !isFocused && processCategory == nil {
                    let shellPID = tab.state.shellPID
                    if shellPID > 0, let resolved = ProcessTree.foregroundProcess(shellPID: shellPID) {
                        processName = resolved
                        processCategory = ProcessIcon.category(for: resolved)
                    }
                }
                let context = TerminalContext(
                    terminalID: tab.id,
                    cwd: tab.workingDirectory,
                    remoteSession: isFocused ? bridge.state.remoteSession : tab.remoteSession,
                    remoteCwd: isFocused ? bridge.state.remoteCwd : tab.remoteWorkingDirectory,
                    gitContext: nil,
                    processName: processName,
                    processPID: processPID,
                    processCategory: processCategory,
                    processMetadata: processMetadata,
                    paneCount: workspace.panes.count,
                    tabCount: pane.tabs.count
                )
                guard let agent = AgentsPlugin.agentSession(from: context, existingStart: nil) else { return nil }
                return WorkspaceAgentSession(
                    id: tab.id,
                    paneID: pane.id,
                    tabID: tab.id,
                    tabTitle: tab.title,
                    isFocused: isFocused,
                    agent: agent
                )
            }
        }
    }
}
