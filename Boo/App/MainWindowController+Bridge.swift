import Cocoa
import Combine

// MARK: - Terminal Bridge

extension MainWindowController {
    /// Schedule a plugin cycle, coalescing multiple events within the same run loop tick.
    /// The highest-priority reason wins when multiple events arrive before the cycle runs.
    func schedulePluginCycle(reason: PluginCycleReason) {
        if let existing = pendingCycleReason {
            pendingCycleReason = Self.higherPriority(existing, reason)
        } else {
            pendingCycleReason = reason
        }
        guard !cycleScheduled else { return }
        cycleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let reason = self.pendingCycleReason else { return }
            self.pendingCycleReason = nil
            self.cycleScheduled = false
            self.runPluginCycle(reason: reason)
        }
    }

    private static func higherPriority(_ a: PluginCycleReason, _ b: PluginCycleReason) -> PluginCycleReason {
        func rank(_ r: PluginCycleReason) -> Int {
            switch r {
            case .titleChanged: return 0
            case .processChanged: return 1

            case .focusChanged: return 2
            case .cwdChanged: return 3
            case .remoteSessionChanged: return 4
            case .workspaceSwitched: return 5
            }
        }
        return rank(b) >= rank(a) ? b : a
    }

    func subscribeToBridge() {
        bridgeCancellables.removeAll()
        contextAnnouncer.subscribe(to: bridge)

        bridge.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                // Sync bridge state to the active tab immediately so tab bar
                // and all UI reads from tab state are always fresh.
                if let ws = self.activeWorkspace,
                    let pane = ws.pane(for: state.paneID)
                {
                    self.coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
                    self.paneViews[pane.id]?.needsDisplay = true
                }
                // Refresh the status bar from AppStore.shared.context.
                // A full plugin cycle is NOT needed here — bridge.events already
                // schedules one with the correct reason for each event type.
                self.refreshStatusBar()
            }
            .store(in: &bridgeCancellables)

        // Socket register/unregister → reevaluateSocketProcess is fanned out by WindowManager.

        bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                let socket = BooSocketServer.shared
                switch event {
                case .directoryChanged(let path):
                    socket.emitCwdChanged(
                        path: path, isRemote: self.bridge.state.remoteSession != nil, paneID: self.bridge.state.paneID)
                    self.schedulePluginCycle(reason: .cwdChanged)

                case .titleChanged(let title):
                    socket.emitTitleChanged(title: title, paneID: self.bridge.state.paneID)
                    self.schedulePluginCycle(reason: .titleChanged)

                case .processChanged(let name):
                    if let workspace = self.activeWorkspace,
                        let pane = workspace.pane(for: self.bridge.state.paneID)
                    {
                        self.coordinator.syncBridgeToTab(pane: pane, tabIndex: pane.activeTabIndex)
                    }
                    socket.emitProcessChanged(
                        name: name,
                        category: self.bridge.state.foregroundProcessCategory ?? ProcessIcon.category(for: name),
                        paneID: self.bridge.state.paneID,
                        pid: self.bridge.state.foregroundProcessPID,
                        metadata: self.bridge.state.foregroundProcessMetadata)
                    self.schedulePluginCycle(reason: .processChanged)

                case .remoteSessionChanged(let session):
                    socket.emitRemoteSessionChanged(session: session, paneID: self.bridge.state.paneID)
                    self.syncRemoteSidebarState()
                    self.schedulePluginCycle(reason: .remoteSessionChanged)

                case .focusChanged(let paneID):
                    socket.emitFocusChanged(paneID: paneID)
                    // Only refresh toolbar — didFocus already runs a synchronous plugin cycle.
                    // Scheduling another async cycle causes sidebar rebuild → GhosttyView focus
                    // callback → didFocus → infinite loop.
                    self.refreshToolbar()

                case .workspaceSwitched(let workspaceID):
                    socket.emitWorkspaceSwitched(workspaceID: workspaceID)
                    self.refreshToolbar()
                    self.schedulePluginCycle(reason: .workspaceSwitched)

                case .remoteDirectoryListed(let path, let entries):
                    self.pluginRegistry.notifyRemoteDirectoryListed(path: path, entries: entries)
                    self.schedulePluginCycle(reason: .cwdChanged)

                case .commandStarted, .commandEnded:
                    // Emitted via paneView delegate before bridge events fire; no further action needed.
                    break

                }
            }
            .store(in: &bridgeCancellables)
    }

    func syncRemoteSidebarState() {
        // isRemoteSidebar and activeRemoteSession are now derived from bridge state.
        // Just trigger a plugin cycle if remote state is relevant.
        let session = bridge.state.remoteSession
        schedulePluginCycle(reason: session != nil ? .remoteSessionChanged : .cwdChanged)
    }
}
