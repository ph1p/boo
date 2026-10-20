import XCTest

@testable import Boo

@MainActor
final class KeyTableTests: XCTestCase {
    private func parse(_ json: String) throws -> (config: KeyTableConfig, problems: [String]) {
        try KeyTableConfig.parse(Data(json.utf8))
    }

    private func chord(_ spec: String) -> KeyChord {
        KeyChord(spec: spec)!
    }

    // MARK: - Keys

    func testChordSpecs() {
        XCTAssertEqual(KeyChord(spec: "ctrl+a"), KeyChord(key: "a", modifiers: .control))
        XCTAssertEqual(KeyChord(spec: "shift+v"), KeyChord(key: "V"), "shift folds into the letter")
        XCTAssertEqual(KeyChord(spec: "V"), KeyChord(key: "V"))
        XCTAssertEqual(KeyChord(spec: "shift+tab"), KeyChord(key: "tab", modifiers: .shift))
        XCTAssertEqual(KeyChord(spec: "esc"), KeyChord(key: "escape"))
        XCTAssertEqual(KeyChord(spec: "cmd+opt+left"), KeyChord(key: "left", modifiers: [.command, .option]))
        XCTAssertEqual(KeyChord(spec: "|"), KeyChord(key: "|"))
        XCTAssertEqual(KeyChord(spec: "ctrl++"), KeyChord(key: "+", modifiers: .control))
        XCTAssertNil(KeyChord(spec: "hyper+a"))
        XCTAssertNil(KeyChord(spec: "shift+1"), "shifted digit depends on the layout")
        XCTAssertNil(KeyChord(spec: "ctrl+"))
        XCTAssertNil(KeyChord(spec: "pagedown"))
    }

    func testChordFromEvent() throws {
        func event(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode))
        }
        XCTAssertEqual(KeyChord(event: try event("a", keyCode: 0, flags: .control)), chord("ctrl+a"))
        XCTAssertEqual(KeyChord(event: try event("V", keyCode: 9, flags: .shift)), chord("V"))
        XCTAssertEqual(KeyChord(event: try event("\u{1b}", keyCode: 53)), chord("escape"))
        XCTAssertEqual(KeyChord(event: try event("\t", keyCode: 48, flags: .shift)), chord("shift+tab"))
    }

    func testDisplay() {
        XCTAssertEqual(chord("ctrl+a").display, "⌃A")
        XCTAssertEqual(chord("shift+tab").display, "⇧⇥")
    }

    // MARK: - Config

    func testParsesTablesAndBindings() throws {
        let (config, problems) = try parse(
            """
            { "leader": "ctrl+b", "timeout": 5,
              "tables": { "root": { "v": "Terminal/Split Right", "x": "send:exit\\n", "w": { "table": "window" } },
                          "window": { "z": "Terminal/Zoom" } } }
            """)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.leader, chord("ctrl+b"))
        XCTAssertEqual(config.timeout, 5)
        XCTAssertEqual(
            config.tables["root"],
            [chord("v"): .action("Terminal/Split Right"), chord("x"): .send("exit\n"), chord("w"): .table("window")])
        XCTAssertEqual(config.tables["window"], [chord("z"): .action("Terminal/Zoom")])
    }

    func testDefaultsAndPerEntryProblems() throws {
        let (config, problems) = try parse(
            #"{ "leader": "nope", "timeout": 0, "tables": { "root": { "pagedown": "X", "v": 3, "s": "Y" } } }"#)
        XCTAssertEqual(config.leader, KeyTableConfig.defaultLeader)
        XCTAssertEqual(config.timeout, 0.5, "clamped")
        XCTAssertEqual(config.tables["root"], [chord("s"): .action("Y")], "good entries survive")
        XCTAssertEqual(
            problems,
            [
                #"leader: "nope" is not a key like "ctrl+a""#,
                #"root › pagedown: not a key like "v", "V" or "ctrl+w""#,
                #"root › v: expected an action id, "send:…" or {"table": …}"#
            ])
        XCTAssertEqual(try parse(#"{"tables":{}}"#).problems, [#"tables: missing the "root" table"#])
        XCTAssertThrowsError(try parse("[1]")) { XCTAssertEqual($0 as? KeyTableError, .notJSON) }
    }

    func testUnknownActionsAndTablesNameTheKey() throws {
        let (config, _) = try parse(
            #"{ "tables": { "root": { "v": "Terminal/Split Rihgt", "d": "Terminal/Split Down", "w": { "table": "win" } } } }"#
        )
        XCTAssertEqual(
            config.problems(knownActionIDs: ["Terminal/Split Down"]),
            [#"root › V: no menu command "Terminal/Split Rihgt""#, #"root › W: no table "win""#])
    }

    // MARK: - Mode

    private func machine() throws -> KeyTableMachine {
        let (config, _) = try parse(
            """
            { "tables": { "root": { "v": "Terminal/Split Right", "w": { "table": "window" } },
                          "window": { "x": "send:hi", "w": { "table": "root" } } } }
            """)
        return KeyTableMachine(config: config)
    }

    func testLeaderThenBinding() throws {
        var m = try machine()
        XCTAssertEqual(m.handle(chord("v")), .passThrough, "mode off: keys are the terminal's")
        XCTAssertEqual(m.handle(chord("ctrl+a")), .consumed)
        XCTAssertEqual(m.table, "root")
        XCTAssertEqual(m.handle(chord("v")), .run(.action("Terminal/Split Right")))
        XCTAssertFalse(m.isActive)
    }

    func testChainedTables() throws {
        var m = try machine()
        _ = m.handle(chord("ctrl+a"))
        XCTAssertEqual(m.handle(chord("w")), .consumed)
        XCTAssertEqual(m.table, "window")
        XCTAssertEqual(m.handle(chord("w")), .consumed)
        XCTAssertEqual(m.table, "root")
        _ = m.handle(chord("w"))
        XCTAssertEqual(m.handle(chord("x")), .run(.send("hi")))
        XCTAssertNil(m.table)
    }

    func testEscapeUnboundAndDoubleLeader() throws {
        var m = try machine()
        _ = m.handle(chord("ctrl+a"))
        XCTAssertEqual(m.handle(chord("escape")), .consumed)
        XCTAssertFalse(m.isActive)

        _ = m.handle(chord("ctrl+a"))
        XCTAssertEqual(m.handle(chord("q")), .consumed, "unbound key ends the mode and goes nowhere")
        XCTAssertFalse(m.isActive)

        _ = m.handle(chord("ctrl+a"))
        XCTAssertEqual(m.handle(chord("ctrl+a")), .passThrough, "leader twice types the leader")
        XCTAssertFalse(m.isActive)
    }

    // MARK: - Runtime

    func testTimeoutEndsTheMode() throws {
        let path = NSTemporaryDirectory() + "boo-keytables-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(#"{"timeout":0.5,"tables":{"root":{"w":{"table":"window"}},"window":{}}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        let tables = KeyTables(path: path)
        tables.reload(knownActionIDs: [], report: false)
        let view = GhosttyView(workingDirectory: "/tmp")
        defer { view.destroy() }
        let leader = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{1}", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(tables.intercept(leader, in: view))
        XCTAssertEqual(tables.indicator, "⌃A …")
        XCTAssertTrue(tables.swallowsRelease(leader))
        XCTAssertFalse(tables.swallowsRelease(leader), "only once")

        let ended = expectation(forNotification: .keyTableChanged, object: tables) { _ in !tables.isActive }
        wait(for: [ended], timeout: 3)
        XCTAssertNil(tables.indicator)
    }

    func testMissingFileIsOff() {
        let tables = KeyTables(path: NSTemporaryDirectory() + "boo-none-\(UUID().uuidString).json")
        tables.reload(knownActionIDs: [], report: false)
        XCTAssertNil(tables.machine)
        XCTAssertNil(tables.indicator)
    }
}
