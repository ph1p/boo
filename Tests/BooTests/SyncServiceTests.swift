import XCTest

@testable import Boo

final class SyncServiceTests: XCTestCase {
    private var root: String!
    private var local: String!
    private var remote: String!
    private var stateFile: String!

    override func setUp() {
        super.setUp()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sync-\(UUID().uuidString)")
        local = (root as NSString).appendingPathComponent("local")
        remote = (root as NSString).appendingPathComponent("remote")
        stateFile = (root as NSString).appendingPathComponent("sync-state.json")
        for dir in [local!, remote!] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    // MARK: - Decisions

    func testDecide() {
        XCTAssertEqual(SyncAction.decide(local: "a", remote: "a", base: nil), .none)
        XCTAssertEqual(SyncAction.decide(local: "b", remote: "a", base: "a"), .push)
        XCTAssertEqual(SyncAction.decide(local: "a", remote: "b", base: "a"), .pull)
        XCTAssertEqual(SyncAction.decide(local: "b", remote: "c", base: "a"), .conflict)
        XCTAssertEqual(SyncAction.decide(local: "b", remote: "c", base: nil), .conflict)
        XCTAssertEqual(SyncAction.decide(local: "a", remote: nil, base: nil), .push)
        XCTAssertEqual(SyncAction.decide(local: nil, remote: "a", base: nil), .pull)
        XCTAssertEqual(SyncAction.decide(local: nil, remote: "a", base: "a"), .deleteRemote)
        XCTAssertEqual(SyncAction.decide(local: "a", remote: nil, base: "a"), .deleteLocal)
        XCTAssertEqual(SyncAction.decide(local: nil, remote: "b", base: "a"), .conflict)
        XCTAssertEqual(SyncAction.decide(local: nil, remote: nil, base: "a"), .none)
    }

    func testPlaceholderTarget() {
        XCTAssertEqual(SyncEngine.placeholderTarget(".rules.json.icloud"), "rules.json")
        XCTAssertNil(SyncEngine.placeholderTarget("rules.json"))
        XCTAssertNil(SyncEngine.placeholderTarget(".icloud"))
    }

    // MARK: - Rounds

    private func engine() -> SyncEngine {
        SyncEngine(localDir: local, remoteDir: remote, stateFile: stateFile)
    }

    private func write(_ dir: String, _ rel: String, _ text: String) {
        let path = (dir as NSString).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ dir: String, _ rel: String) -> String? {
        try? String(contentsOfFile: (dir as NSString).appendingPathComponent(rel), encoding: .utf8)
    }

    func testPushPullAndConflict() {
        write(local, "rules.json", "L1")
        write(remote, "profiles.json", "R1")
        write(local, "themes/a.conf", "theme")
        var result = engine().run()
        XCTAssertEqual(Set(result.pushed), ["rules.json", "themes/a.conf"])
        XCTAssertEqual(result.pulled, ["profiles.json"])
        XCTAssertEqual(read(remote, "rules.json"), "L1")
        XCTAssertEqual(read(remote, "themes/a.conf"), "theme")
        XCTAssertEqual(read(local, "profiles.json"), "R1")

        // Remote-only edit pulls; then both edit → conflict, untouched.
        write(remote, "rules.json", "R2")
        result = engine().run()
        XCTAssertEqual(result.pulled, ["rules.json"])
        XCTAssertEqual(read(local, "rules.json"), "R2")

        write(local, "rules.json", "L3")
        write(remote, "rules.json", "R3")
        result = engine().run()
        XCTAssertEqual(result.conflicts, ["rules.json"])
        XCTAssertEqual(read(local, "rules.json"), "L3")
        XCTAssertEqual(read(remote, "rules.json"), "R3")

        try? engine().resolve("rules.json", keepLocal: false)
        XCTAssertEqual(read(local, "rules.json"), "R3")
        XCTAssertTrue(engine().run().conflicts.isEmpty)
    }

    func testDeletionPropagates() {
        write(local, "themes/a.conf", "x")
        _ = engine().run()
        try? FileManager.default.removeItem(atPath: (local as NSString).appendingPathComponent("themes/a.conf"))
        let result = engine().run()
        XCTAssertEqual(result.pushed, ["themes/a.conf"])
        XCTAssertNil(read(remote, "themes/a.conf"))
        XCTAssertNil(SyncState.load(from: stateFile).hashes["themes/a.conf"])
    }

    func testPlaceholderIsPendingNotDeleted() {
        write(local, "snippets.json", "s")
        _ = engine().run()
        try? FileManager.default.removeItem(atPath: (remote as NSString).appendingPathComponent("snippets.json"))
        write(remote, ".snippets.json.icloud", "")
        let result = engine().run()
        XCTAssertEqual(result.pending, ["snippets.json"])
        XCTAssertEqual(read(local, "snippets.json"), "s")
    }

    func testSettingsCanonicalAndApplied() {
        var settings: [String: Any] = ["fontSize": 13.0, "themeName": "Dark"]
        var applied: [String: Any]?
        let e = engine()
        e.settingsSnapshot = { settings }
        e.applySettings = { applied = $0 }
        XCTAssertEqual(e.run().pushed, ["settings.json"])

        // Reformatted but equal remote is no change.
        write(remote, "settings.json", #"{"themeName":"Dark","fontSize":13.0}"#)
        XCTAssertTrue(e.run().pulled.isEmpty)

        write(remote, "settings.json", #"{"themeName":"Light","fontSize":13.0}"#)
        XCTAssertEqual(e.run().pulled, ["settings.json"])
        XCTAssertEqual(applied?["themeName"] as? String, "Light")
        settings = applied ?? [:]
        XCTAssertTrue(e.run().pushed.isEmpty)
    }
}
