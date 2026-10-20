import Cocoa
import XCTest

@testable import Boo

@MainActor
final class ActionRegistryTests: XCTestCase {
    private final class Target: NSObject, NSMenuItemValidation {
        var ran: [String] = []
        @objc func enabledAction(_ sender: Any?) { ran.append("enabled") }
        @objc func disabledAction(_ sender: Any?) { ran.append("disabled") }
        func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action != #selector(disabledAction(_:)) }
    }

    private func makeMenu(_ target: Target) -> NSMenu {
        let main = NSMenu()
        let top = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Terminal")
        let split = NSMenuItem(title: "Split Right", action: #selector(Target.enabledAction(_:)), keyEquivalent: "d")
        split.target = target
        menu.addItem(split)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Off", action: #selector(Target.disabledAction(_:)), keyEquivalent: "")
        off.target = target
        menu.addItem(off)
        menu.addItem(NSMenuItem(title: "Plugin Header", action: nil, keyEquivalent: ""))
        let sub = NSMenu(title: "Select Pane")
        let left = NSMenuItem(
            title: "Left", action: #selector(Target.enabledAction(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        left.keyEquivalentModifierMask = [.command, .option]
        left.target = target
        sub.addItem(left)
        let parent = NSMenuItem(title: "Select Pane", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        top.submenu = menu
        main.addItem(top)
        return main
    }

    func testIDsArePathsAndSkipNonCommands() {
        let target = Target()
        let ids = ActionRegistry.actions(in: makeMenu(target)).map(\.id)
        XCTAssertEqual(ids, ["Terminal/Split Right", "Terminal/Off", "Terminal/Select Pane/Left"])
    }

    func testShortcutDisplay() {
        let target = Target()
        let actions = ActionRegistry.actions(in: makeMenu(target))
        XCTAssertEqual(actions[0].shortcut, "\u{2318}D")
        XCTAssertNil(actions[1].shortcut)
        XCTAssertEqual(actions[2].shortcut, "\u{2325}\u{2318}\u{2190}")
    }

    func testDisabledActionDoesNotRun() {
        let target = Target()
        let menu = makeMenu(target)
        XCTAssertFalse(ActionRegistry.action(id: "Terminal/Off", in: menu)!.isEnabled)
        XCTAssertFalse(ActionRegistry.action(id: "Terminal/Off", in: menu)!.perform())
        XCTAssertTrue(ActionRegistry.action(id: "Terminal/Split Right", in: menu)!.perform())
        XCTAssertEqual(target.ran, ["enabled"])
    }

    func testShortcutGroupsCollapseNumberedRuns() {
        let main = NSMenu()
        let top = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")
        let target = Target()
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)", action: #selector(Target.enabledAction(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = target
            menu.addItem(item)
        }
        top.submenu = menu
        main.addItem(top)
        XCTAssertEqual(
            ActionRegistry.shortcutGroups(in: main),
            [.init(title: "View", entries: [.init(title: "Tab 1-9", shortcut: "\u{2325}\u{2318}1-9")])])
    }

    func testLaunchSpecFromSocketCommand() {
        XCTAssertNil(LaunchSpec.from(json: ["cwd": "/tmp"]))
        XCTAssertNil(LaunchSpec.from(json: ["command": ""]))
        XCTAssertEqual(
            LaunchSpec.from(json: ["command": "pnpm dev", "env": ["PORT": "4000", "N": 1]]),
            LaunchSpec(command: "pnpm dev", env: ["PORT": "4000"]))
    }
}
