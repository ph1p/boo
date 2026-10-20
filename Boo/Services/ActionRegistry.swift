import Cocoa

/// One command of the main menu, for the command palette, key tables and the
/// shortcuts settings page.
@MainActor
struct MenuAction {
    /// The menu path joined with "/" ("Terminal/Split Right"); stable across launches.
    let id: String
    let title: String
    /// Top-level menu down to the item.
    let path: [String]
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    /// Shown only while a modifier is held; it duplicates another item's command.
    let isAlternate: Bool
    let item: NSMenuItem

    /// "⇧⌘D", or nil without a key equivalent.
    var shortcut: String? {
        keyEquivalent.isEmpty ? nil : ActionRegistry.display(key: keyEquivalent, modifiers: modifiers)
    }

    /// Asks the item's target, as AppKit's menu validation would.
    var isEnabled: Bool {
        guard let action = item.action,
            let target = NSApplication.shared.target(forAction: action, to: item.target, from: item)
        else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Sends the item's action through the responder chain. False when disabled.
    @discardableResult
    func perform() -> Bool {
        guard isEnabled, let action = item.action else { return false }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
    }
}

/// Enumerates the live main menu, plugin items included, so every surface
/// that lists commands stays in step with the menu.
@MainActor
enum ActionRegistry {
    static func actions(in menu: NSMenu? = NSApplication.shared.mainMenu) -> [MenuAction] {
        guard let menu else { return [] }
        var result: [MenuAction] = []
        var seen = Set<String>()
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items where !item.isSeparatorItem {
                let itemPath = path + [item.title]
                if let submenu = item.submenu {
                    walk(submenu, path: itemPath)
                    continue
                }
                // Plugin headers and "No Plugin Commands" have no action; AppKit's
                // window list changes with every window.
                guard let action = item.action, action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                    !path.isEmpty
                else { continue }
                var id = itemPath.joined(separator: "/")
                if item.isAlternate { id += " (alternate)" }
                guard seen.insert(id).inserted else { continue }
                result.append(
                    MenuAction(
                        id: id, title: item.title, path: itemPath, keyEquivalent: item.keyEquivalent,
                        modifiers: item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]),
                        isAlternate: item.isAlternate, item: item))
            }
        }
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            walk(submenu, path: [top.title])
        }
        return result
    }

    static func action(id: String, in menu: NSMenu? = NSApplication.shared.mainMenu) -> MenuAction? {
        actions(in: menu).first { $0.id == id }
    }

    // MARK: - Shortcuts page

    struct ShortcutGroup: Equatable {
        let title: String
        let entries: [ShortcutEntry]
    }

    struct ShortcutEntry: Hashable {
        let title: String
        let shortcut: String
    }

    /// Every bound shortcut, grouped by top-level menu. Numbered runs bound to
    /// the digit keys ("Tab 1" … "Tab 9" on ⌥⌘1–9) collapse into one "Tab 1-9" row.
    static func shortcutGroups(in menu: NSMenu? = NSApplication.shared.mainMenu) -> [ShortcutGroup] {
        var groups: [ShortcutGroup] = []
        for action in actions(in: menu) where !action.keyEquivalent.isEmpty {
            let group = action.path[0] == "Boo" ? "General" : action.path[0]
            // Nested items ("Select Pane > Left") read as "Select Pane Left".
            var title = action.path.dropFirst().joined(separator: " ")
            var shortcut = action.shortcut ?? ""
            if let run = numberedRun(title: title, key: action.keyEquivalent) {
                guard run.number == 1 else { continue }
                title = run.prefix + " 1-9"
                shortcut = display(key: "", modifiers: action.modifiers) + "1-9"
            }
            let entry = ShortcutEntry(title: title, shortcut: shortcut)
            if let index = groups.firstIndex(where: { $0.title == group }) {
                if !groups[index].entries.contains(entry) {
                    groups[index] = ShortcutGroup(title: group, entries: groups[index].entries + [entry])
                }
            } else {
                groups.append(ShortcutGroup(title: group, entries: [entry]))
            }
        }
        return groups
    }

    /// "Tab 3" bound to "3" → ("Tab", 3).
    private static func numberedRun(title: String, key: String) -> (prefix: String, number: Int)? {
        guard let number = Int(key), (1...9).contains(number), title.hasSuffix(" \(number)") else { return nil }
        return (String(title.dropLast(2)), number)
    }

    nonisolated static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var display = ""
        if modifiers.contains(.control) { display += "\u{2303}" }
        if modifiers.contains(.option) { display += "\u{2325}" }
        if modifiers.contains(.shift) { display += "\u{21E7}" }
        if modifiers.contains(.command) { display += "\u{2318}" }
        switch key {
        case "": break
        case "\r": display += "\u{23CE}"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): display += "\u{2190}"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): display += "\u{2192}"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): display += "\u{2191}"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): display += "\u{2193}"
        default: display += key.uppercased()
        }
        return display
    }
}
