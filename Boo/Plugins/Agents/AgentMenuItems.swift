import Cocoa

/// What an agent menu item acts on: the agent to start, and the pane and tab
/// the menu was opened on (nil: the active ones).
final class AgentMenuRequest: NSObject {
    let kind: AgentKind?
    let paneID: UUID?
    let tabID: UUID?

    init(kind: AgentKind? = nil, paneID: UUID? = nil, tabID: UUID? = nil) {
        self.kind = kind
        self.paneID = paneID
        self.tabID = tabID
    }
}

/// The agent entries of the tab bar's menus. Their actions go up the
/// responder chain to the window's `MainWindowController`.
@MainActor enum AgentMenuItems {
    /// The prompt "Ask Agent About This Tab" starts an agent with.
    static func askAboutTabPrompt(handle: String) -> String {
        "Look at Boo tab \(handle): run `boo read \(handle)` to see its screen. "
            + "Tell me in a few lines what it shows and whether something went wrong, then wait for my questions."
    }

    /// "New Claude Tab"… per installed agent, then "New Agent…", for the + menu.
    /// Empty while agents are off.
    static func newTabItems(paneID: UUID) -> [NSMenuItem] {
        guard AppSettings.shared.agentsEnabled else { return [] }
        var items = AgentsPlugin.installedKinds.map { kind in
            item(
                "New \(kind.shortName) Tab", #selector(MainWindowController.newAgentTabAction(_:)),
                AgentMenuRequest(kind: kind, paneID: paneID))
        }
        items.append(item("New Agent…", #selector(MainWindowController.newAgentAction(_:)), nil))
        return items
    }

    /// "Start Agent Here" (one entry per installed agent) and "Ask Agent About
    /// This Tab" for a tab's context menu. Empty while agents are off.
    static func tabItems(tabID: UUID, paneID: UUID) -> [NSMenuItem] {
        let kinds = AgentsPlugin.installedKinds
        guard AppSettings.shared.agentsEnabled, !kinds.isEmpty else { return [] }
        let start = NSMenuItem(title: "Start Agent Here", action: nil, keyEquivalent: "")
        start.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let submenu = NSMenu()
        for kind in kinds {
            submenu.addItem(
                item(
                    kind.displayName, #selector(MainWindowController.newAgentTabAction(_:)),
                    AgentMenuRequest(kind: kind, paneID: paneID, tabID: tabID), icon: false))
        }
        start.submenu = submenu
        let ask = item(
            "Ask Agent About This Tab", #selector(MainWindowController.askAgentAboutTabAction(_:)),
            AgentMenuRequest(kind: nil, paneID: paneID, tabID: tabID))
        ask.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: nil)
        return [start, ask]
    }

    private static func item(
        _ title: String, _ action: Selector, _ request: AgentMenuRequest?, icon: Bool = true
    )
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = request
        if icon { item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) }
        return item
    }
}
