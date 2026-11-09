import Cocoa
import XCTest

@testable import Boo

final class FocusHistoryTests: XCTestCase {
    private let ws = UUID()
    private func place(_ pane: UUID = UUID()) -> FocusLocation {
        FocusLocation(workspaceID: ws, paneID: pane, tabID: nil)
    }

    func testBackAndForwardWalkTheList() {
        var history = FocusHistory()
        let (a, b, c) = (place(), place(), place())
        for location in [a, b, c] { history.record(location) }
        XCTAssertEqual(history.move(by: -1, isValid: { _ in true }), b)
        XCTAssertEqual(history.move(by: -1, isValid: { _ in true }), a)
        XCTAssertNil(history.move(by: -1, isValid: { _ in true }))
        XCTAssertEqual(history.move(by: 1, isValid: { _ in true }), b)
    }

    func testRecordingDropsForwardEntriesAndDuplicates() {
        var history = FocusHistory()
        let (a, b, c) = (place(), place(), place())
        for location in [a, b] { history.record(location) }
        _ = history.move(by: -1, isValid: { _ in true })
        history.record(c)
        history.record(c)
        XCTAssertEqual(history.entries, [a, c])
        XCTAssertNil(history.move(by: 1, isValid: { _ in true }))
    }

    func testNavigatingIsNotRecordedAndGoneEntriesAreSkipped() {
        var history = FocusHistory()
        let (a, b, c) = (place(), place(), place())
        for location in [a, b, c] { history.record(location) }
        XCTAssertEqual(history.move(by: -1, isValid: { $0 != b }), a)
        history.isNavigating = true
        history.record(c)
        XCTAssertEqual(history.current, a)
    }

    func testHistoryIsCapped() {
        var history = FocusHistory()
        for _ in 0..<(FocusHistory.limit + 10) { history.record(place()) }
        XCTAssertEqual(history.entries.count, FocusHistory.limit)
        XCTAssertEqual(history.index, FocusHistory.limit - 1)
    }
}

final class NavigationTests: XCTestCase {
    func testNextVisibleIndexWrapsAndSkipsHidden() {
        let hidden: Set<Int> = [1, 2]
        XCTAssertEqual(MainWindowController.nextVisibleIndex(from: 0, step: 1, count: 4) { hidden.contains($0) }, 3)
        XCTAssertEqual(MainWindowController.nextVisibleIndex(from: 3, step: 1, count: 4) { hidden.contains($0) }, 0)
        XCTAssertEqual(MainWindowController.nextVisibleIndex(from: 0, step: -1, count: 4) { hidden.contains($0) }, 3)
        XCTAssertNil(MainWindowController.nextVisibleIndex(from: 0, step: 1, count: 1) { _ in false })
        XCTAssertNil(MainWindowController.nextVisibleIndex(from: 0, step: 1, count: 3) { $0 != 0 })
    }

    @MainActor
    func testBackTabShortcutsNormalize() {
        let shiftTab = ShortcutOverrides.Shortcut(key: "\t", modifiers: [.control, .shift])
        XCTAssertEqual(shiftTab.key, ShortcutOverrides.Shortcut.backTab)
        XCTAssertEqual(ShortcutOverrides.spec(for: shiftTab), "ctrl+shift+tab")
        XCTAssertEqual(ShortcutOverrides.parse("ctrl+shift+tab"), shiftTab)
        XCTAssertEqual(shiftTab.display, "\u{2303}\u{21E7}\u{21E5}")
        XCTAssertEqual(ActionRegistry.display(key: "\t", modifiers: .control), "\u{2303}\u{21E5}")
    }

    @MainActor
    func testControlTabAndDigitsGoToTheMenu() throws {
        func event(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                    keyCode: keyCode))
        }
        XCTAssertTrue(GhosttyView.isMenuCtrlKey(try event("\t", 48, .control)))
        XCTAssertTrue(GhosttyView.isMenuCtrlKey(try event("1", 18, .control)))
        XCTAssertFalse(GhosttyView.isMenuCtrlKey(try event("1", 18, [.control, .option])))
        XCTAssertFalse(GhosttyView.isMenuCtrlKey(try event("a", 0, .control)))
    }

    func testPanePickerLabels() {
        XCTAssertEqual(PanePickerOverlay.paneIndex(for: "1"), 0)
        XCTAssertEqual(PanePickerOverlay.paneIndex(for: "9"), 8)
        XCTAssertEqual(PanePickerOverlay.paneIndex(for: "A"), 9)
        XCTAssertNil(PanePickerOverlay.paneIndex(for: "0"))
        XCTAssertNil(PanePickerOverlay.paneIndex(for: "ab"))
    }

    @MainActor
    func testPercentFiltersPanes() {
        XCTAssertEqual(PaletteQuery("%vim"), PaletteQuery(kind: .pane, text: "vim"))
    }
}

final class TmuxPresetTests: XCTestCase {
    func testPresetParsesCleanly() throws {
        let parsed = try KeyTableConfig.parse(Data(KeyTableConfig.tmuxPresetJSON.utf8))
        XCTAssertEqual(parsed.problems, [])
        XCTAssertEqual(parsed.config.leader, KeyTableConfig.defaultLeader)
        let root = try XCTUnwrap(parsed.config.tables[KeyTableConfig.rootTable])
        XCTAssertNil(root[KeyChord(key: "a", modifiers: .control)], "leader twice types ⌃A on its own")
        XCTAssertEqual(root[KeyChord(key: "%")], .action("Terminal/Split Right"))
    }

    @MainActor
    func testPresetActionsExistInTheMenu() {
        let controller = MainWindowController()
        controller.setupMenuItems()
        let known = Set(ActionRegistry.actions().map(\.id))
        XCTAssertEqual(KeyTableConfig.tmuxPreset.problems(knownActionIDs: known), [])
    }

    @MainActor
    func testPresetLoadsOnlyWithoutAFile() throws {
        let missing = NSTemporaryDirectory() + "boo-none-\(UUID().uuidString).json"
        let tables = KeyTables(path: missing)
        tables.reload(knownActionIDs: [], report: false, preset: true)
        XCTAssertEqual(tables.machine?.config, KeyTableConfig.tmuxPreset)

        let path = NSTemporaryDirectory() + "boo-keytables-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(#"{"leader":"ctrl+b","tables":{"root":{}}}"#.utf8).write(to: URL(fileURLWithPath: path))
        let fromFile = KeyTables(path: path)
        fromFile.reload(knownActionIDs: [], report: false, preset: true)
        XCTAssertEqual(fromFile.machine?.config.leader, KeyChord(key: "b", modifiers: .control))
    }
}
