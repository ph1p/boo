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
    func testShortcutsPageListsMenuShortcuts() {
        let controller = MainWindowController()
        controller.setupMenuItems()

        let entries = ActionRegistry.shortcutGroups().flatMap(\.entries)
        let byTitle = Dictionary(entries.map { ($0.title, $0.shortcut) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byTitle["Split Right"], "\u{2318}D")
        XCTAssertEqual(byTitle["Select Pane Left"], "\u{2325}\u{2318}\u{2190}")
        XCTAssertEqual(byTitle["Workspace 1-9"], "\u{2318}1-9")
        XCTAssertEqual(byTitle["Jump to Bookmark 1-9"], "\u{2303}1-9")
        XCTAssertTrue(entries.contains(.init(title: "Tab 1-9", shortcut: "\u{21E7}\u{2318}1-9")))
        XCTAssertFalse(entries.contains { $0.title == "Tab 2" })
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

            // Items in nested submenus ("Select Pane > Left") read as "Select Pane Left".
            let title = item.parent?.parent != nil ? "\(item.parent!.title) \(item.title)" : item.title
            return MenuShortcutItem(
                title: title,
                keyEquivalent: item.keyEquivalent,
                modifiers: item.normalizedModifierFlags)
        }
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

extension NSMenuItem {
    fileprivate var normalizedModifierFlags: NSEvent.ModifierFlags {
        keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
    }
}
