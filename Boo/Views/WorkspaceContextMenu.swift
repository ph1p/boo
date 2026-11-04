import Cocoa

/// Workspace right-click menu shared by the top toolbar and the vertical workspace bar.
/// Every item targets `target` and carries the workspace index in its `tag`.
@MainActor enum WorkspaceContextMenu {
    struct Actions {
        let edit: Selector
        let togglePin: Selector
        let moveToNewWindow: Selector
        let close: Selector
    }

    static func make(
        index: Int, isPinned: Bool, canMoveToNewWindow: Bool, extraItems: [NSMenuItem],
        target: AnyObject, actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.tag = index
            menu.addItem(item)
        }

        add("Edit Workspace…", actions.edit)
        add(isPinned ? "Unpin" : "Pin", actions.togglePin)
        menu.addItem(.separator())

        if !isPinned && canMoveToNewWindow {
            add("Move to New Window", actions.moveToNewWindow)
        }
        if !extraItems.isEmpty {
            extraItems.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        if !isPinned {
            add("Close", actions.close)
        }
        return menu
    }
}
