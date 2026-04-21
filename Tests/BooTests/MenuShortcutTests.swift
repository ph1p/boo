import Cocoa
import XCTest

@testable import Boo

final class MenuShortcutTests: XCTestCase {
    @MainActor
    func testUndoKeepsPlainCommandZ() {
        let controller = MainWindowController()
        controller.setupMenuItems()

        let undoItems = menuItems(matching: "z", modifiers: [.command])
        XCTAssertTrue(undoItems.contains { $0.title == "Undo" })
        XCTAssertFalse(undoItems.contains { $0.title == "Reopen Closed Tab" })
    }

    @MainActor
    func testReopenClosedTabDoesNotConflictWithUndoOrRedo() {
        let controller = MainWindowController()
        controller.setupMenuItems()

        let reopenItem = menuItem(titled: "Reopen Closed Tab")
        XCTAssertEqual(reopenItem?.keyEquivalent, "z")
        XCTAssertEqual(reopenItem?.normalizedModifierFlags, [.command, .option])
    }

    @MainActor
    func testBuiltinMenuShortcutsDoNotCollide() {
        let controller = MainWindowController()
        controller.setupMenuItems()

        let items = builtinShortcutItems()
        let collisions = Dictionary(grouping: items, by: \.combo)
            .filter { _, items in items.count > 1 }
            .map { combo, items in "\(combo): \(items.map(\.title).joined(separator: ", "))" }

        XCTAssertTrue(collisions.isEmpty, "Shortcut collisions: \(collisions.joined(separator: "; "))")
    }

    @MainActor
    func testSettingsShortcutViewMatchesBuiltinMenuShortcuts() {
        let controller = MainWindowController()
        controller.setupMenuItems()

        let displayed = Set(
            ShortcutsSettingsView.groups.flatMap { group in
                group.1.map { ShortcutEntry(title: $0.0, display: $0.1) }
            })
        let expected = Set(
            builtinShortcutItems().flatMap { item in
                expandSettingsEntries(for: item)
            })

        XCTAssertEqual(displayed.subtracting(expected), [])
        XCTAssertEqual(expected.subtracting(displayed), [])
    }

    @MainActor
    private func menuItems(matching keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        return allMenuItems(in: mainMenu).filter { item in
            item.keyEquivalent.lowercased() == keyEquivalent
                && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                    == normalizedModifiers
        }
    }

    @MainActor
    private func menuItem(titled title: String) -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        return allMenuItems(in: mainMenu).first { $0.title == title }
    }

    @MainActor
    private func builtinShortcutItems() -> [MenuShortcutItem] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        return allMenuItems(in: mainMenu).compactMap { item in
            guard !item.keyEquivalent.isEmpty,
                item.submenu == nil,
                item.title != "Quit Boo",
                item.title != "About Boo",
                item.title != "Check for Updates...",
                item.title != "No Plugin Commands"
            else { return nil }

            return MenuShortcutItem(
                title: item.title,
                keyEquivalent: item.keyEquivalent,
                modifiers: item.normalizedModifierFlags)
        }
    }

    private func expandSettingsEntries(for item: MenuShortcutItem) -> [ShortcutEntry] {
        switch item.title {
        case "Workspace 1", "Tab 1", "Jump to Bookmark 1":
            return [ShortcutEntry(title: shortcutRangeTitle(for: item.title), display: shortcutRangeDisplay(for: item))]
        case let title
        where title.hasPrefix("Workspace ")
            || title.hasPrefix("Tab ")
            || title.hasPrefix("Jump to Bookmark "):
            return []
        case "Settings...":
            return [ShortcutEntry(title: "Settings", display: displayShortcut(for: item))]
        case "Open Folder...":
            return [ShortcutEntry(title: "Open Folder", display: displayShortcut(for: item))]
        case "Bookmark Current Directory":
            return [ShortcutEntry(title: "Bookmark Directory", display: displayShortcut(for: item))]
        default:
            return [ShortcutEntry(title: item.title, display: displayShortcut(for: item))]
        }
    }

    private func shortcutRangeTitle(for title: String) -> String {
        if title.hasPrefix("Workspace ") { return "Switch Workspace 1-9" }
        if title.hasPrefix("Tab ") { return "Switch Tab 1-9" }
        return "Jump to Bookmark 1-9"
    }

    private func shortcutRangeDisplay(for item: MenuShortcutItem) -> String {
        var display = displayModifiers(item.modifiers)
        display += "1-9"
        return display
    }

    private func displayShortcut(for item: MenuShortcutItem) -> String {
        displayModifiers(item.modifiers) + displayKey(item.keyEquivalent)
    }

    private func displayModifiers(_ modifiers: NSEvent.ModifierFlags) -> String {
        var display = ""
        if modifiers.contains(.control) { display += "\u{2303}" }
        if modifiers.contains(.option) { display += "\u{2325}" }
        if modifiers.contains(.shift) { display += "\u{21E7}" }
        if modifiers.contains(.command) { display += "\u{2318}" }
        return display
    }

    private func displayKey(_ key: String) -> String {
        if key == "\r" { return "\u{23CE}" }
        return key.uppercased()
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems(in:)) ?? [])
        }
    }
}

private struct MenuShortcutItem {
    let title: String
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    var combo: String { "\(modifiers.rawValue):\(keyEquivalent.lowercased())" }
}

private struct ShortcutEntry: Hashable {
    let title: String
    let display: String
}

extension NSMenuItem {
    fileprivate var normalizedModifierFlags: NSEvent.ModifierFlags {
        keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
    }
}
