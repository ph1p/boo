import Cocoa

/// Agent entries in the menus: the Agents menu, the tab bar's + menu and a
/// tab's context menu. All do nothing while agents are off.
extension MainWindowController {
    /// The Agents menu of the main menu; hidden while agents are off.
    func makeAgentsMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        menuItem.title = "Agents"
        menuItem.submenu = NSMenu(title: "Agents")
        fillAgentsMenu(menuItem)
        return menuItem
    }

    /// Refill the Agents menu: after the agents switch flips, and once the
    /// installed agents are known.
    func rebuildAgentsMenu() {
        guard let (mainMenu, menuItem) = ownedTopMenuItem(titled: "Agents") else { return }
        fillAgentsMenu(menuItem)
        ShortcutOverrides.apply(to: mainMenu)
    }

    /// Off: the menu is hidden and empty, so its shortcuts and palette rows go too.
    private func fillAgentsMenu(_ menuItem: NSMenuItem) {
        guard let menu = menuItem.submenu else { return }
        menu.removeAllItems()
        let enabled = AppSettings.shared.agentsEnabled
        menuItem.isHidden = !enabled
        guard enabled else { return }
        let newAgent = NSMenuItem(title: "New Agent…", action: #selector(newAgentAction(_:)), keyEquivalent: "n")
        newAgent.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(newAgent)
        for kind in AgentsPlugin.installedKinds {
            let item = NSMenuItem(
                title: "New \(kind.shortName) Tab", action: #selector(newAgentTabAction(_:)), keyEquivalent: "")
            item.representedObject = AgentMenuRequest(kind: kind)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let crew = NSMenuItem(title: "Show Crew", action: #selector(showCrewAction(_:)), keyEquivalent: "a")
        crew.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(crew)
        let jump = NSMenuItem(
            title: "Jump to Next Waiting Agent", action: #selector(jumpToNextWaitingAgentAction(_:)),
            keyEquivalent: "J")
        jump.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(jump)
    }

    /// The pane a menu request names, else the active one.
    private func paneView(for request: AgentMenuRequest?) -> PaneView? {
        if let id = request?.paneID, let pv = paneViews[id] { return pv }
        return activeWorkspace.flatMap { paneViews[$0.activePaneID] }
    }

    /// Starts the request's agent in a new tab: beside (and in the group of)
    /// the tab it names, else at the end of the active pane.
    @discardableResult
    private func startAgentTab(for request: AgentMenuRequest?, prompt: String) -> UUID? {
        let picked = AgentCrewUIState.shared.taskAgent
        let fallback = AgentsPlugin.installedAgents.contains(picked) ? picked : AgentsPlugin.installedKinds.first
        guard let kind = request?.kind ?? fallback,
            let pv = paneView(for: request)
        else { return nil }
        let tab = request?.tabID.flatMap { id in pv.pane.tabs.first { $0.id == id } } ?? pv.pane.activeTab
        return startAgentTab(
            kind: kind, prompt: prompt, workingDirectory: tab?.workingDirectory ?? AppSettings.shared.defaultFolder,
            in: pv, group: request?.tabID == nil ? nil : tab?.groupID)
    }

    /// "New Claude Tab"…: the agent, with no prompt, in a new tab.
    @objc func newAgentTabAction(_ sender: Any?) {
        startAgentTab(for: (sender as? NSMenuItem)?.representedObject as? AgentMenuRequest, prompt: "")
    }

    /// An agent beside the tab that reads its screen and says what it shows.
    @objc func askAgentAboutTabAction(_ sender: Any?) {
        let request = (sender as? NSMenuItem)?.representedObject as? AgentMenuRequest
        guard let tabID = request?.tabID else { return }
        startAgentTab(
            for: request, prompt: AgentMenuItems.askAboutTabPrompt(handle: AgentCrew.shared.handle(for: tabID)))
    }

    /// The new-agent form under the crew list's "New Agent" button.
    @objc func newAgentAction(_ sender: Any?) {
        guard showCrew() else { return }
        // After the sidebar laid out the crew list the form anchors to.
        DispatchQueue.main.async { AgentCrewUIState.shared.open(.newTask) }
    }

    @objc func showCrewAction(_ sender: Any?) {
        showCrew()
    }

    /// Shows the agents sidebar tab, opening the sidebar if needed.
    @discardableResult
    func showCrew() -> Bool {
        guard AppSettings.shared.agentsEnabled, let ctx = pluginRegistry.lastContext else { return false }
        if !sidebarVisible { toggleSidebar(userInitiated: true) }
        displacedPluginTabID = nil
        activatePluginTab(SidebarTabID(AppSettings.agentsPluginID), context: ctx)
        window?.contentView?.layoutSubtreeIfNeeded()
        return true
    }
}
