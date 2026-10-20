import Carbon.HIToolbox
import Cocoa
import XCTest

@testable import Boo

@MainActor
final class QuickTerminalTests: XCTestCase {

    // MARK: - HotKeySpec

    func testParsesModifiersAndKeys() throws {
        let space = try XCTUnwrap(HotKeySpec.parse("opt+space"))
        XCTAssertEqual(space.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(space.modifiers, UInt32(optionKey))
        XCTAssertEqual(space.display, "⌥Space")

        let t = try XCTUnwrap(HotKeySpec.parse("Cmd + Shift + T"))
        XCTAssertEqual(t.keyCode, UInt32(kVK_ANSI_T))
        XCTAssertEqual(t.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(t.display, "⇧⌘T")

        XCTAssertEqual(HotKeySpec.parse("ctrl+`")?.display, "⌃`")
        XCTAssertEqual(HotKeySpec.parse("alt+7")?.keyCode, UInt32(kVK_ANSI_7))
    }

    func testFunctionKeyNeedsNoModifier() {
        XCTAssertEqual(HotKeySpec.parse("f12")?.keyCode, UInt32(kVK_F12))
        XCTAssertEqual(HotKeySpec.parse("f12")?.display, "F12")
        XCTAssertNil(HotKeySpec.parse("f13"))
    }

    func testRejectsInvalidSpecs() {
        XCTAssertNil(HotKeySpec.parse("space"), "a plain key would swallow typing system-wide")
        XCTAssertNil(HotKeySpec.parse(""))
        XCTAssertNil(HotKeySpec.parse("opt+"))
        XCTAssertNil(HotKeySpec.parse("hyper+space"))
        XCTAssertNil(HotKeySpec.parse("opt+pageup"))
    }

    func testMenuKeyEquivalent() throws {
        let space = try XCTUnwrap(HotKeySpec.parse("opt+space")).menuKeyEquivalent
        XCTAssertEqual(space.key, " ")
        XCTAssertEqual(space.modifiers, [.option])

        let t = try XCTUnwrap(HotKeySpec.parse("ctrl+shift+t")).menuKeyEquivalent
        XCTAssertEqual(t.key, "t")
        XCTAssertEqual(t.modifiers, [.control, .shift])

        let f1 = try XCTUnwrap(HotKeySpec.parse("f1")).menuKeyEquivalent
        XCTAssertEqual(f1.key.unicodeScalars.first?.value, UInt32(NSF1FunctionKey))
    }

    // MARK: - Geometry

    func testFrameHangsFromTopOfVisibleArea() {
        let visible = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let frame = QuickTerminalController.frame(in: visible, heightFraction: 0.4)
        XCTAssertEqual(frame, NSRect(x: 100, y: 530, width: 1000, height: 320))
    }

    // MARK: - Session

    func testRestoreIsLazy() {
        let controller = QuickTerminalController()
        XCTAssertNil(controller.session)
        let saved = QuickTerminalSession(tabs: ["/tmp", "/usr"], activeIndex: 1)
        controller.restore(saved)
        XCTAssertEqual(controller.session, saved, "pending tabs survive a save before the first show")
        XCTAssertTrue(controller.hosts.isEmpty, "no shell starts before the panel is shown")
    }

    func testSnapshotKeepsQuickTerminalSession() throws {
        var snapshot = SessionSnapshot(activeWorkspaceIndex: 0, workspaces: [])
        snapshot.quickTerminal = QuickTerminalSession(tabs: ["/tmp"], activeIndex: 0)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.quickTerminal, snapshot.quickTerminal)

        let old = #"{"activeWorkspaceIndex":0,"workspaces":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionSnapshot.self, from: Data(old.utf8)).quickTerminal)
    }

    // MARK: - Settings

    func testHeightIsClamped() {
        let settings = AppSettings.shared
        let original = settings.quickTerminalHeight
        defer { settings.quickTerminalHeight = original }
        settings.quickTerminalHeight = 2
        XCTAssertEqual(settings.quickTerminalHeight, 0.9)
        settings.quickTerminalHeight = 0
        XCTAssertEqual(settings.quickTerminalHeight, 0.2)
    }

    // MARK: - Menu routing

    func testSplitActionsAreDisabledInPanel() {
        let controller = QuickTerminalController()
        func valid(_ action: Selector, tag: Int = 0) -> Bool {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return controller.validateMenuItem(item)
        }
        XCTAssertFalse(valid(#selector(QuickTerminalController.splitVerticalAction(_:))))
        XCTAssertFalse(valid(#selector(QuickTerminalController.toggleSidebarAction(_:))))
        XCTAssertFalse(valid(#selector(QuickTerminalController.switchToTabAction(_:)), tag: 0), "no tabs yet")
        XCTAssertFalse(valid(#selector(QuickTerminalController.jumpToNextPromptAction(_:))))
        XCTAssertTrue(valid(#selector(QuickTerminalController.newTabAction(_:))))
        XCTAssertTrue(valid(#selector(QuickTerminalController.toggleQuickTerminalAction(_:))))
    }
}
