import Cocoa
import SwiftUI

extension Workspace {
    /// Whether the workspace can join stored groups: pinned ones stay apart,
    /// and a tmux window's group is its session.
    var joinsGroups: Bool { !isPinned && tmuxWindowID == nil }
}

/// tmux windows shown as workspaces of this window; see `TmuxControlClient`.
extension MainWindowController: TmuxHost {
    func tmuxOpenWorkspace(
        window: String, name: String, tree: SplitTree, programs: [UUID: String], focus: Bool
    )
        -> UUID?
    {
        guard let first = tree.leafIDs.first else { return nil }
        let folder = activeWorkspace?.folderPath ?? AppSettings.shared.defaultFolder
        let workspace = Workspace(folderPath: folder, id: UUID(), splitTree: tree, activePaneID: first)
        workspace.customName = name
        workspace.tmuxWindowID = window
        for pane in tmuxPanes(programs, folder: folder) { workspace.restorePane(pane) }
        if focus {
            presentNewWorkspace(workspace)
        } else {
            // Shown in the bar; its bridges start when it is first activated.
            let active = appState.activeWorkspaceIndex
            appState.addWorkspace(workspace)
            appState.setActiveWorkspace(active)
            refreshToolbar()
        }
        return workspace.id
    }

    func tmuxApplyLayout(workspace id: UUID, tree: SplitTree, programs: [UUID: String]) {
        guard let workspace = appState.workspace(withID: id) else { return }
        let isVisible = workspace === activeWorkspace
        if isVisible { previousFocusedTabID = nil }
        let gone = workspace.adopt(tree: tree, newPanes: tmuxPanes(programs, folder: workspace.folderPath))
        for paneID in gone { workspacePaneViews[id]?.removeValue(forKey: paneID)?.stopAll() }
        guard isVisible else { return }
        splitContainer.update(tree: workspace.displayedTree)
        DispatchQueue.main.async { [weak self] in
            guard let self, let ws = self.activeWorkspace, ws.id == id else { return }
            for pv in self.paneViews.values {
                pv.tabDragCoordinator = self.tabDragCoordinator
                if pv.currentTerminalView == nil { pv.startActiveSession() }
            }
            self.refreshAllSurfaces()
            self.syncCoordinatorPaneViews()
            self.updatePaneCloseButtons()
        }
    }

    func tmuxRenameWorkspace(_ id: UUID, name: String) {
        appState.workspace(withID: id)?.customName = name
        refreshToolbar()
    }

    func tmuxCloseWorkspace(_ id: UUID) {
        guard let index = appState.workspaces.firstIndex(where: { $0.id == id }) else { return }
        forceCloseWorkspace(at: index)
    }

    func tmuxShowWorkspace(_ id: UUID) {
        guard let index = appState.workspaces.firstIndex(where: { $0.id == id }) else { return }
        activateWorkspace(index)
    }

    /// One single-tab pane per leaf, each running its bridge program.
    private func tmuxPanes(_ programs: [UUID: String], folder: String) -> [Pane] {
        programs.map { paneID, program in
            let pane = Pane(id: paneID)
            pane.addTab(workingDirectory: folder)
            pane.tmuxOwned = true
            if let tab = pane.tabs.last { GhosttyView.pendingLaunch[tab.id] = LaunchSpec(program: program) }
            return pane
        }
    }
}

extension MainWindowController {
    /// Switches to a regular workspace when tmux owns the active one (its
    /// panes only show tmux), opening one if needed. Returns the active workspace.
    func activateContentWorkspace() -> Workspace? {
        guard let active = activeWorkspace else { return nil }
        guard active.tmuxWindowID != nil else { return active }
        if let index = appState.workspaces.lastIndex(where: { $0.tmuxWindowID == nil }) {
            activateWorkspace(index)
        } else {
            openWorkspace(path: active.folderPath)
        }
        return activeWorkspace
    }

    /// A tmux pane holds no tabs of its own, so a new tab (Cmd+T included)
    /// opens in a regular workspace. New tmux windows come from the chip menu.
    func paneView(
        _ paneView: PaneView, redirectNewTab contentType: ContentType, workingDirectory: String, url: URL?,
        launch: LaunchSpec?
    ) -> UUID? {
        activateContentWorkspace().flatMap { paneViews[$0.activePaneID] }?
            .addNewTab(contentType: contentType, workingDirectory: workingDirectory, url: url, launch: launch)
    }

    /// A tmux pane dropped on another pane of its session: tmux moves it and
    /// the layout change updates Boo. tmux panes and Boo tabs don't mix.
    func tmuxTabDrop(source: UUID, dest: UUID, zone: TabDropZone) {
        guard let tmux = TmuxControlClient.owning(pane: source), tmux.owns(pane: dest) else { return }
        switch zone {
        case .tabBarGroup:
            break
        case .swapPanes, .center, .tabBarInsert:
            tmux.swap(pane: source, with: dest)
        case .left, .right, .top, .bottom, .workspaceEdge:
            guard let placement = zone.splitPlacement else { break }
            tmux.join(pane: source, to: dest, toward: placement.edge, full: placement.wholeWorkspace)
        }
    }

    /// A tmux pane dropped on a workspace pill: it joins that tmux window.
    func tmuxMovePane(_ paneID: UUID, toWorkspace workspace: Workspace) {
        TmuxControlClient.owning(pane: paneID)?.join(
            pane: paneID, to: workspace.activePaneID, toward: .right, full: false)
    }

    /// A tmux pane dragged out of the window becomes a tmux window of its own.
    func tmuxBreakOut(_ paneID: UUID) {
        TmuxControlClient.owning(pane: paneID)?.breakOut(pane: paneID)
    }

    func paneView(_ paneView: PaneView, redirectPluginView view: AnyView, title: String, icon: String) -> UUID? {
        activateContentWorkspace().flatMap { paneViews[$0.activePaneID] }?
            .addPluginViewTab(view: view, title: title, icon: icon)
    }
}

/// A terminal running `tmux -CC`, taken out of its pane while tmux shows
/// its windows as workspaces. Its shell keeps running off-screen.
@MainActor
final class TmuxParkedGateway {
    let view: GhosttyView
    let tab: Pane.Tab
    let paneID: UUID
    let index: Int
    /// Opened by Boo only to run tmux; closed instead of restored on detach.
    let ephemeral: Bool

    init(view: GhosttyView, tab: Pane.Tab, paneID: UUID, index: Int, ephemeral: Bool) {
        self.view = view
        self.tab = tab
        self.paneID = paneID
        self.index = index
        self.ephemeral = ephemeral
    }
}

// MARK: - Gateway terminal

extension MainWindowController {
    /// Tabs Boo opened to run tmux (palette, menu, reattach).
    static var ephemeralTmuxTabs: Set<UUID> = []
    /// The ssh host each of those tabs runs tmux on.
    static var tmuxRemoteHosts: [UUID: String] = [:]

    /// Starts (or attaches to) a tmux session in a tab Boo closes again
    /// on detach. `name` nil makes a new session; `host` runs it over ssh.
    func startTmuxSession(_ name: String?, host: String?) {
        guard let workspace = activateContentWorkspace(), let pane = paneViews[workspace.activePaneID] else { return }
        let command = TmuxSessions.command(attach: name, host: host)
        let cwd = host == nil ? workspace.folderPath : NSHomeDirectory()
        guard let tabID = pane.addNewTab(workingDirectory: cwd, launch: LaunchSpec(command: command)) else { return }
        Self.ephemeralTmuxTabs.insert(tabID)
        if let host {
            Self.tmuxRemoteHosts[tabID] = host
            TmuxSessions.remember(host: host)
        }
    }

    /// Takes the terminal that started control mode out of its pane. False
    /// when it is not in this window's active workspace and stays put.
    func tmuxGatewayEntered(_ gateway: GhosttyView, client: TmuxControlClient) -> Bool {
        client.onChange = { [weak self] in self?.refreshToolbar() }
        client.remoteHost = gateway.tabID.flatMap { Self.tmuxRemoteHosts.removeValue(forKey: $0) }
        guard let tabID = gateway.tabID, let workspace = activeWorkspace,
            let source = paneViews.values.first(where: { pv in pv.pane.tabs.contains { $0.id == tabID } }),
            let index = source.pane.tabs.firstIndex(where: { $0.id == tabID })
        else { return false }
        let ephemeral = Self.ephemeralTmuxTabs.remove(tabID) != nil
        let lastInPane = source.pane.tabs.count == 1
        let lastPane = workspace.splitTree.leafIDs.count == 1
        // A workspace never goes empty: its last terminal gets a fresh shell beside it.
        if lastInPane, lastPane {
            source.addNewTab(workingDirectory: source.pane.tabs[index].workingDirectory, focus: false)
        }
        guard let tab = source.pane.extractTab(at: index) else { return false }
        guard let view = source.extractGhosttyView(for: tabID) else {
            source.pane.insertTab(tab, at: index)
            return false
        }
        client.parked = TmuxParkedGateway(
            view: view, tab: tab, paneID: source.paneID, index: index, ephemeral: ephemeral)
        if source.pane.tabs.isEmpty {
            closeEmptyPane(source.paneID)
        } else {
            source.startActiveSession()
            source.layoutTerminalView()
            source.needsDisplay = true
        }
        refreshToolbar()
        return true
    }

    /// Control mode ended: a parked terminal returns to its pane (or the
    /// active one), or closes when Boo opened it only for tmux.
    func tmuxGatewayExited(_ gateway: GhosttyView, client: TmuxControlClient) {
        let label = client.label
        let remote = client.remoteHost
        let session = client.canReattach ? client.session : nil
        defer {
            refreshToolbar()
            if let session { offerReattach(label: label, session: session, host: remote) }
        }
        guard let parked = client.parked else { return }
        client.parked = nil
        if parked.ephemeral {
            DispatchQueue.main.async { gateway.destroy() }
            return
        }
        guard let workspace = activateContentWorkspace(),
            let dest = paneViews[parked.paneID] ?? paneViews[workspace.activePaneID]
        else {
            DispatchQueue.main.async { gateway.destroy() }
            return
        }
        let index = min(parked.index, dest.pane.tabs.count)
        dest.pane.insertTab(parked.tab, at: index)
        dest.insertGhosttyView(parked.view, for: parked.tab.id)
        dest.forceActivateTab(index)
        workspace.activePaneID = dest.paneID
        window?.makeFirstResponder(dest.ghosttyView)
        syncCoordinatorPaneViews()
    }

    /// The window is closing: parked terminals go with it.
    func destroyParkedTmuxGateways() {
        for client in TmuxControlClient.all where client.hostedBy === self {
            client.parked?.view.destroy()
        }
    }

    private func offerReattach(label: String, session: String, host: String?) {
        let reattach = BooAlert.ToastAction(title: "Reattach") { [weak self] in
            self?.startTmuxSession(session, host: host)
        }
        BooAlert.showTransient("Detached from tmux \(label)", actions: [reattach])
    }
}

// MARK: - Session chip

extension MainWindowController {
    /// Workspace-bar group ids of tmux sessions start with this; they are
    /// never stored in `AppSettings.workspaceGroups`.
    static let tmuxChipPrefix = "tmux:"

    /// The chip a tmux window's workspace sits under: one per session.
    func tmuxChip(for workspace: Workspace) -> (id: String, name: String)? {
        guard workspace.tmuxWindowID != nil, let client = TmuxControlClient.owning(workspace: workspace.id)
        else { return nil }
        return (Self.tmuxChipPrefix + client.id.uuidString, "tmux · \(client.label)")
    }

    static func tmuxClient(chipID: String) -> TmuxControlClient? {
        guard chipID.hasPrefix(tmuxChipPrefix) else { return nil }
        return UUID(uuidString: String(chipID.dropFirst(tmuxChipPrefix.count))).flatMap(TmuxControlClient.client(id:))
    }

    /// The chip's menu: the session's windows, then what to do with the session.
    func tmuxChipMenuItems(_ client: TmuxControlClient) -> [NSMenuItem] {
        let active = activeWorkspace?.id
        var items: [NSMenuItem] = client.windowList.map { window in
            let item = ClosureMenuItem(title: window.name) { [weak self] in
                self?.tmuxShowWorkspace(window.workspace)
            }
            item.state = window.workspace == active ? .on : .off
            return item
        }
        items.append(.separator())
        items.append(
            ClosureMenuItem(title: "New Window") { [weak client] in client?.newWindow() })
        items.append(
            ClosureMenuItem(title: "Rename Session…") { [weak self, weak client] in
                guard let client else { return }
                self?.promptForText(
                    title: "Rename tmux Session", initial: client.session ?? "", confirm: "Rename"
                ) { [weak client] name in client?.renameSession(name) }
            })
        items.append(.separator())
        items.append(
            ClosureMenuItem(title: "Detach") { [weak client] in client?.detach() })
        items.append(
            ClosureMenuItem(title: "Kill Session…") { [weak self, weak client] in
                guard let client else { return }
                self?.confirmKillTmuxSession(client)
            })
        return items
    }

    private func confirmKillTmuxSession(_ client: TmuxControlClient) {
        guard let window else { return }
        let count = client.windowList.count
        let alert = NSAlert()
        alert.messageText = "Kill tmux session \(client.label)?"
        alert.informativeText =
            "Its \(count == 1 ? "window" : "\(count) windows") and every program running in them end. Detach instead to keep them running."
        alert.addButton(withTitle: "Kill Session")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak client] response in
            guard response == .alertFirstButtonReturn else { return }
            client?.killSession()
        }
    }
}

// MARK: - Pane menu

extension MainWindowController {
    /// "tmux" submenu for the pane's ⋯ menu: the session's own items inside
    /// a tmux window, otherwise sessions to start or attach.
    func tmuxMenuItem(for pane: PaneView) -> NSMenuItem? {
        guard AppSettings.shared.tmuxIntegration else { return nil }
        let menu = NSMenu()
        if let workspace = appState.workspaceContainingPane(pane.paneID),
            let client = TmuxControlClient.owning(workspace: workspace.id)
        {
            tmuxChipMenuItems(client).forEach(menu.addItem)
        } else {
            menu.addItem(
                ClosureMenuItem(title: "New Session") { [weak self] in self?.startTmuxSession(nil, host: nil) })
            let local = TmuxSessions.local()
            if !local.isEmpty { menu.addItem(.separator()) }
            for session in local {
                let item = ClosureMenuItem(title: "Attach \(session.name)") { [weak self] in
                    self?.startTmuxSession(session.name, host: nil)
                }
                item.toolTip = session.summary
                menu.addItem(item)
            }
            let hosts = TmuxSessions.hosts
            if !hosts.isEmpty { menu.addItem(.separator()) }
            for host in hosts {
                menu.addItem(
                    ClosureMenuItem(title: "New Session on \(host)") { [weak self] in
                        self?.startTmuxSession(nil, host: host)
                    })
            }
        }
        let item = NSMenuItem(title: "tmux", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: PaneView.tmuxSymbol, accessibilityDescription: nil)
        item.submenu = menu
        return item
    }
}

extension MainWindowController {
    /// Pops the session menu under the pointer (a click on the session's chip).
    func showTmuxChipMenu(_ client: TmuxControlClient) {
        guard let view = window?.contentView else { return }
        let menu = NSMenu()
        tmuxChipMenuItems(client).forEach(menu.addItem)
        let point = view.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}
