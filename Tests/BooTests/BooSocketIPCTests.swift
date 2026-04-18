import Combine
import XCTest

@testable import Boo

// MARK: - Subscription Infrastructure Tests

@MainActor
final class BooSocketSubscriptionTests: BooSocketIntegrationTestCase {

    private func roundTrip(_ command: [String: Any]) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(command: command)
        }
    }

    // MARK: - Subscribe/Unsubscribe

    func testSubscribeReturnsSubscribedEvents() throws {
        let response = try roundTrip(["cmd": "subscribe", "events": ["cwd_changed", "process_changed"]])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(socketStringSet(response["subscribed"]), Set(["cwd_changed", "process_changed"]))
    }

    func testSubscribeWildcard() throws {
        let response = try roundTrip(["cmd": "subscribe", "events": ["*"]])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(socketStringSet(response["subscribed"]), BooSocketServer.availableEvents)
    }

    func testSubscribeRejectsInvalidEvents() throws {
        let response = try roundTrip(["cmd": "subscribe", "events": ["nonexistent_event"]])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "no valid events")
    }

    func testSubscribeMissingEventsArray() throws {
        let response = try roundTrip(["cmd": "subscribe"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "missing events array")
    }

    func testUnsubscribeOK() throws {
        try withBooSocketClient { client in
            _ = try client.roundTrip(command: ["cmd": "subscribe", "events": ["cwd_changed"]])
            let response = try client.roundTrip(command: ["cmd": "unsubscribe", "events": ["cwd_changed"]])
            XCTAssertEqual(response["ok"] as? Bool, true)

            let hasSubscription = BooSocketServer.shared.queue.sync {
                BooSocketServer.shared.subscriptions[client.fd] != nil
            }
            XCTAssertFalse(hasSubscription)
        }
    }

    // MARK: - Event Push

    func testSubscriberReceivesEvent() throws {
        try withBooSocketClient { client in
            let subscribeResponse = try client.roundTrip(command: ["cmd": "subscribe", "events": ["cwd_changed"]])
            XCTAssertEqual(socketStringSet(subscribeResponse["subscribed"]), Set(["cwd_changed"]))

            let paneID = UUID()
            BooSocketServer.shared.emitCwdChanged(path: "/tmp/project", isRemote: false, paneID: paneID)

            let event = try XCTUnwrap(try client.readJSONObject(timeout: 1.0))
            XCTAssertEqual(event["event"] as? String, "cwd_changed")

            let payload = try XCTUnwrap(event["data"] as? [String: Any])
            XCTAssertEqual(payload["path"] as? String, "/tmp/project")
            XCTAssertEqual(payload["is_remote"] as? Bool, false)
            XCTAssertEqual(payload["pane_id"] as? String, paneID.uuidString)
        }
    }

    func testNonSubscriberDoesNotReceiveEvent() throws {
        try withBooSocketClient { client in
            _ = try client.roundTrip(command: ["cmd": "subscribe", "events": ["theme_changed"]])
            BooSocketServer.shared.emitCwdChanged(path: "/tmp/nope", isRemote: false, paneID: UUID())
            XCTAssertNil(try client.readJSONObject(timeout: 0.2))
        }
    }
}

// MARK: - Query Command Tests

@MainActor
final class BooSocketQueryTests: BooSocketIntegrationTestCase {

    private var originalContext: TerminalContext!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            originalContext = AppStore.shared.context
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppStore.shared.updateContext(originalContext)
        }
        try await super.tearDown()
    }

    private func roundTrip(_ command: [String: Any]) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(command: command)
        }
    }

    func testListThemes() throws {
        let response = try roundTrip(["cmd": "list_themes"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let themes = try XCTUnwrap(response["themes"] as? [String])
        XCTAssertTrue(themes.contains("Default Dark"))
    }

    func testGetContext() throws {
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp/project",
            remoteSession: .container(target: "dev-container", tool: .docker),
            remoteCwd: "/workspace",
            gitContext: TerminalContext.GitContext(
                branch: "main",
                repoRoot: "/tmp/project",
                isDirty: true,
                changedFileCount: 3,
                stagedCount: 1,
                aheadCount: 2,
                behindCount: 1,
                lastCommitShort: "abc1234"
            ),
            processName: "zsh",
            paneCount: 2,
            tabCount: 3
        )
        AppStore.shared.updateContext(context)

        let response = try roundTrip(["cmd": "get_context"])
        XCTAssertEqual(response["ok"] as? Bool, true)

        let payload = try XCTUnwrap(response["context"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(payload["process_name"] as? String, "zsh")
        XCTAssertEqual(payload["pane_count"] as? Int, 2)
        XCTAssertEqual(payload["tab_count"] as? Int, 3)
        XCTAssertEqual(payload["is_remote"] as? Bool, true)
        XCTAssertEqual(payload["remote_cwd"] as? String, "/workspace")

        let remote = try XCTUnwrap(payload["remote_session"] as? [String: Any])
        XCTAssertEqual(remote["type"] as? String, "container")
        XCTAssertEqual(remote["target"] as? String, "dev-container")
        XCTAssertEqual(remote["tool"] as? String, "docker")

        let git = try XCTUnwrap(payload["git"] as? [String: Any])
        XCTAssertEqual(git["branch"] as? String, "main")
        XCTAssertEqual(git["repo_root"] as? String, "/tmp/project")
        XCTAssertEqual(git["is_dirty"] as? Bool, true)
        XCTAssertEqual(git["changed_count"] as? Int, 3)
        XCTAssertEqual(git["staged_count"] as? Int, 1)
        XCTAssertEqual(git["ahead"] as? Int, 2)
        XCTAssertEqual(git["behind"] as? Int, 1)
        XCTAssertEqual(git["last_commit"] as? String, "abc1234")
    }

    func testGetTheme() throws {
        let expectedTheme = AppSettings.shared.theme
        let response = try roundTrip(["cmd": "get_theme"])
        XCTAssertEqual(response["ok"] as? Bool, true)

        let theme = try XCTUnwrap(response["theme"] as? [String: Any])
        XCTAssertEqual(theme["name"] as? String, expectedTheme.name)
        XCTAssertEqual(theme["is_dark"] as? Bool, expectedTheme.isDark)
    }

    func testGetSettings() throws {
        let settings = AppSettings.shared
        let response = try roundTrip(["cmd": "get_settings"])
        XCTAssertEqual(response["ok"] as? Bool, true)

        let payload = try XCTUnwrap(response["settings"] as? [String: Any])
        XCTAssertEqual(payload["theme_name"] as? String, settings.themeName)
        XCTAssertEqual(payload["auto_theme"] as? Bool, settings.autoTheme)
        XCTAssertEqual(payload["font_name"] as? String, settings.fontName)
        XCTAssertEqual(payload["font_size"] as? Double, Double(settings.fontSize))
        XCTAssertEqual(payload["cursor_style"] as? String, settings.cursorStyle.label.lowercased())
        XCTAssertEqual(
            payload["sidebar_position"] as? String,
            settings.sidebarPosition == .left ? "left" : "right"
        )
        XCTAssertEqual(
            payload["sidebar_density"] as? String,
            settings.sidebarDensity == .compact ? "compact" : "comfortable"
        )
        XCTAssertEqual(payload["show_hidden_files"] as? Bool, settings.showHiddenFiles)
        XCTAssertEqual(payload["auto_check_updates"] as? Bool, settings.autoCheckUpdates)
        XCTAssertEqual(payload["status_bar_show_path"] as? Bool, settings.statusBarShowPath)
        XCTAssertEqual(payload["status_bar_show_time"] as? Bool, settings.statusBarShowTime)
        XCTAssertEqual(payload["status_bar_show_pane_info"] as? Bool, settings.statusBarShowPaneInfo)
        XCTAssertEqual(payload["status_bar_show_shell"] as? Bool, settings.statusBarShowShell)
        XCTAssertEqual(payload["status_bar_show_connection"] as? Bool, settings.statusBarShowConnection)
    }

    func testSerializeContextCoversQueryFields() {
        // Verifies the serialization that get_context would return
        let ctx = TerminalContext(
            terminalID: UUID(), cwd: "/home/user",
            remoteSession: nil, gitContext: nil,
            processName: "zsh", paneCount: 2, tabCount: 3
        )
        let dict = BooSocketServer.serializeContext(ctx)
        XCTAssertEqual(dict["cwd"] as? String, "/home/user")
        XCTAssertEqual(dict["process_name"] as? String, "zsh")
        XCTAssertEqual(dict["pane_count"] as? Int, 2)
        XCTAssertEqual(dict["tab_count"] as? Int, 3)
    }
}

// MARK: - Status Bar Command Tests

@MainActor
final class BooSocketStatusBarTests: BooSocketIntegrationTestCase {

    private func roundTrip(_ command: [String: Any]) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(command: command)
        }
    }

    func testStatusBarSetTracksOwnerConnection() throws {
        try withBooSocketClient { client in
            let response = try client.roundTrip(
                command: [
                    "cmd": "statusbar.set",
                    "id": "test-build",
                    "text": "Building...",
                    "icon": "hammer",
                    "tint": "yellow",
                    "position": "left",
                    "priority": 30
                ])
            XCTAssertEqual(response["ok"] as? Bool, true)

            let segment = BooSocketServer.shared.queue.sync {
                BooSocketServer.shared.externalSegments["test-build"]
            }
            XCTAssertEqual(segment?.text, "Building...")
            XCTAssertEqual(segment?.icon, "hammer")
            XCTAssertEqual(segment?.tint, "yellow")
            XCTAssertEqual(segment?.position, .left)
            XCTAssertEqual(segment?.priority, 30)
            XCTAssertNotNil(segment?.ownerFD)

            client.close()
            BooSocketTestSupport.waitUntil {
                BooSocketServer.shared.queue.sync {
                    BooSocketServer.shared.externalSegments["test-build"] == nil
                }
            }
        }
    }

    func testStatusBarClear() throws {
        try withBooSocketClient { client in
            _ = try client.roundTrip(command: ["cmd": "statusbar.set", "id": "active", "text": "Hello"])
            let clearResponse = try client.roundTrip(command: ["cmd": "statusbar.clear", "id": "active"])
            XCTAssertEqual(clearResponse["ok"] as? Bool, true)

            let segment = BooSocketServer.shared.queue.sync {
                BooSocketServer.shared.externalSegments["active"]
            }
            XCTAssertNil(segment)
        }
    }

    func testStatusBarList() throws {
        try withBooSocketClient { client in
            _ = try client.roundTrip(command: ["cmd": "statusbar.set", "id": "segment-a", "text": "A"])
            let response = try client.roundTrip(command: ["cmd": "statusbar.list"])
            XCTAssertEqual(response["ok"] as? Bool, true)

            let segments = try XCTUnwrap(response["segments"] as? [[String: Any]])
            let segment = segments.first { ($0["id"] as? String) == "segment-a" }
            XCTAssertEqual(segment?["text"] as? String, "A")
            XCTAssertEqual(segment?["position"] as? String, "right")
            XCTAssertEqual(segment?["priority"] as? Int, 50)
        }
    }

    func testStatusBarSegmentBookkeeping() {
        // Unit test: directly manipulate the segments dict
        let server = BooSocketServer.shared
        let info = BooSocketServer.ExternalSegmentInfo(
            id: "test", text: "Hello", icon: nil, tint: nil,
            position: .left, priority: 10, ownerFD: 999
        )
        server.queue.sync { server.externalSegments["test"] = info }
        let stored = server.queue.sync { server.externalSegments["test"] }
        XCTAssertEqual(stored?.text, "Hello")
        server.queue.sync { server.externalSegments.removeAll() }
    }

    func testStatusBarSetMissingID() throws {
        let response = try roundTrip(["cmd": "statusbar.set", "text": "no id"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "missing id or text")
    }
}

// MARK: - Serialization Unit Tests

@MainActor
final class BooSocketSerializationTests: XCTestCase {

    func testSerializeContextEmpty() {
        let ctx = TerminalContext.empty
        let dict = BooSocketServer.serializeContext(ctx)
        XCTAssertEqual(dict["cwd"] as? String, "")
        XCTAssertEqual(dict["process_name"] as? String, "")
        XCTAssertEqual(dict["is_remote"] as? Bool, false)
        XCTAssertEqual(dict["pane_count"] as? Int, 0)
    }

    func testSerializeContextWithGit() {
        let git = TerminalContext.GitContext(
            branch: "main", repoRoot: "/repo",
            isDirty: true, changedFileCount: 3,
            stagedCount: 1, aheadCount: 2, behindCount: 0,
            lastCommitShort: "abc1234"
        )
        let ctx = TerminalContext(
            terminalID: UUID(), cwd: "/repo",
            remoteSession: nil, gitContext: git,
            processName: "vim", paneCount: 2, tabCount: 3
        )
        let dict = BooSocketServer.serializeContext(ctx)
        XCTAssertEqual(dict["cwd"] as? String, "/repo")
        XCTAssertEqual(dict["process_name"] as? String, "vim")

        let gitDict = dict["git"] as? [String: Any]
        XCTAssertNotNil(gitDict)
        XCTAssertEqual(gitDict?["branch"] as? String, "main")
        XCTAssertEqual(gitDict?["is_dirty"] as? Bool, true)
        XCTAssertEqual(gitDict?["changed_count"] as? Int, 3)
    }

    func testSerializeContextWithRemoteSSH() {
        let ctx = TerminalContext(
            terminalID: UUID(), cwd: "/local",
            remoteSession: .ssh(host: "user@server", alias: "myhost"),
            remoteCwd: "/home/user",
            gitContext: nil, processName: "",
            paneCount: 1, tabCount: 1
        )
        let dict = BooSocketServer.serializeContext(ctx)
        XCTAssertEqual(dict["is_remote"] as? Bool, true)
        XCTAssertEqual(dict["remote_cwd"] as? String, "/home/user")

        let remote = dict["remote_session"] as? [String: Any]
        XCTAssertEqual(remote?["type"] as? String, "ssh")
        XCTAssertEqual(remote?["host"] as? String, "user@server")
        XCTAssertEqual(remote?["alias"] as? String, "myhost")
    }

    func testSerializeRemoteSessionDocker() {
        let dict = BooSocketServer.serializeRemoteSession(
            .container(target: "my-container", tool: .docker))
        XCTAssertEqual(dict["type"] as? String, "container")
        XCTAssertEqual(dict["target"] as? String, "my-container")
    }
}

// MARK: - External Status Bar Segment Unit Tests

@MainActor
final class ExternalStatusBarSegmentTests: XCTestCase {

    func testSegmentCreation() {
        let info = BooSocketServer.ExternalSegmentInfo(
            id: "build", text: "Building...", icon: "hammer",
            tint: "yellow", position: .left, priority: 10, ownerFD: 5
        )
        let segment = ExternalStatusBarSegment(info: info)
        XCTAssertEqual(segment.id, "external.build")
        XCTAssertEqual(segment.priority, 10)
        XCTAssertTrue(segment.position == .left)
    }

    func testSegmentAlwaysVisible() {
        let info = BooSocketServer.ExternalSegmentInfo(
            id: "test", text: "Test", icon: nil,
            tint: nil, position: .right, priority: 50, ownerFD: 5
        )
        let segment = ExternalStatusBarSegment(info: info)
        let state = StatusBarState(
            currentDirectory: "/tmp", paneCount: 1, tabCount: 1,
            runningProcess: "", isRemote: false
        )
        XCTAssertTrue(segment.isVisible(settings: AppSettings.shared, state: state))
    }
}
