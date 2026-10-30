import XCTest

@testable import Boo

@MainActor
final class ShortcutOverridesTests: XCTestCase {

    private final class Target: NSObject {
        @objc func run(_ sender: Any?) {}
    }

    private let target = Target()

    private func menu() -> NSMenu {
        let main = NSMenu()
        let top = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Terminal")
        let split = NSMenuItem(title: "Split Right", action: #selector(Target.run(_:)), keyEquivalent: "d")
        split.target = target
        let clear = NSMenuItem(title: "Clear", action: #selector(Target.run(_:)), keyEquivalent: "")
        clear.target = target
        sub.addItem(split)
        sub.addItem(clear)
        top.submenu = sub
        main.addItem(top)
        return main
    }

    func testParseAndSpecRoundTrip() {
        for spec in ["shift+cmd+d", "ctrl+opt+left", "cmd+space", "f5", "cmd++", "ctrl+cmd+return"] {
            let shortcut = ShortcutOverrides.parse(spec)
            XCTAssertNotNil(shortcut, spec)
            XCTAssertEqual(ShortcutOverrides.spec(for: shortcut!), spec)
        }
        XCTAssertEqual(ShortcutOverrides.parse(""), ShortcutOverrides.Shortcut.none)
        XCTAssertNil(ShortcutOverrides.parse("hyper+d"))
        XCTAssertNil(ShortcutOverrides.parse("cmd+ab"))
    }

    func testApplyRebindsAndUnbinds() {
        let main = menu()
        ShortcutOverrides.apply(["Terminal/Split Right": "", "Terminal/Clear": "cmd+opt+k"], to: main)
        let items = main.items[0].submenu!.items
        XCTAssertEqual(items[0].keyEquivalent, "")
        XCTAssertEqual(items[1].keyEquivalent, "k")
        XCTAssertEqual(items[1].keyEquivalentModifierMask, [.command, .option])
    }

    func testDefaultSurvivesSecondApply() throws {
        let main = menu()
        let overrides = ["Terminal/Split Right": "cmd+shift+e"]
        ShortcutOverrides.apply(overrides, to: main)
        ShortcutOverrides.apply(overrides, to: main)
        let action = try XCTUnwrap(ActionRegistry.action(id: "Terminal/Split Right", in: main))
        XCTAssertEqual(action.shortcut, "\u{21E7}\u{2318}E")
        XCTAssertEqual(ShortcutOverrides.defaultShortcut(for: action).display, "\u{2318}D")
    }

    func testConflictsIgnoreSelfAndMatchModifiers() {
        let actions = ActionRegistry.actions(in: menu())
        let cmdD = ShortcutOverrides.Shortcut(key: "d", modifiers: [.command])
        XCTAssertEqual(
            ShortcutOverrides.conflicts(with: cmdD, excluding: "Terminal/Clear", in: actions).map(\.id),
            ["Terminal/Split Right"])
        XCTAssertTrue(ShortcutOverrides.conflicts(with: cmdD, excluding: "Terminal/Split Right", in: actions).isEmpty)
        let optD = ShortcutOverrides.Shortcut(key: "d", modifiers: [.option])
        XCTAssertTrue(ShortcutOverrides.conflicts(with: optD, excluding: "Terminal/Clear", in: actions).isEmpty)
    }
}
