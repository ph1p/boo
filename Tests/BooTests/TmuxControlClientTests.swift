import XCTest

@testable import Boo

@MainActor
final class TmuxControlClientTests: XCTestCase {
    private final class FakeGateway: TmuxGateway {
        var commands: [String] = []
        var tmuxGridSize: TmuxProtocol.CellSize? = .init(columns: 80, rows: 24)
        func writeTmuxCommand(_ line: String) { commands.append(line) }
    }

    private final class FakeHost: TmuxHost {
        struct Opened {
            let window: String, name: String, tree: SplitTree, programs: [UUID: String], focus: Bool, id: UUID
        }
        var opened: [Opened] = []
        var layouts: [(UUID, SplitTree, [UUID: String])] = []
        var renamed: [(UUID, String)] = []
        var closed: [UUID] = []

        func tmuxOpenWorkspace(
            window: String, name: String, tree: SplitTree, programs: [UUID: String], focus: Bool
        )
            -> UUID?
        {
            let id = UUID()
            opened.append(.init(window: window, name: name, tree: tree, programs: programs, focus: focus, id: id))
            return id
        }
        func tmuxApplyLayout(workspace: UUID, tree: SplitTree, programs: [UUID: String]) {
            layouts.append((workspace, tree, programs))
        }
        func tmuxRenameWorkspace(_ workspace: UUID, name: String) { renamed.append((workspace, name)) }
        func tmuxCloseWorkspace(_ workspace: UUID) { closed.append(workspace) }
        func tmuxShowWorkspace(_ workspace: UUID) {}

        var focused: [(UUID, UUID)] = []
        var selected: [UUID] = []
        var zooms: [(UUID, UUID?)] = []
        var changes: [(UUID, String?, String?)] = []
        var paused: [(UUID, Bool)] = []
        var errors: [String] = []
        var clipboard: [String] = []
        var choice: Set<String>?
        var asked: [String] = []

        func tmuxFocusPane(_ pane: UUID, workspace: UUID) { focused.append((pane, workspace)) }
        func tmuxSelectWorkspace(_ workspace: UUID) { selected.append(workspace) }
        func tmuxSetZoom(workspace: UUID, pane: UUID?) { zooms.append((workspace, pane)) }
        func tmuxPaneChanged(_ pane: UUID, directory: String?, command: String?) {
            changes.append((pane, directory, command))
        }
        func tmuxPanePaused(_ pane: UUID, paused: Bool) { self.paused.append((pane, paused)) }
        func tmuxShowError(_ message: String) { errors.append(message) }
        func tmuxChooseWindows(
            _ windows: [TmuxProtocol.WindowInfo], session: String, choose: @escaping (Set<String>?) -> Void
        ) {
            asked = windows.map(\.id)
            choose(choice)
        }
        func tmuxCopyToClipboard(_ text: String) { clipboard.append(text) }
    }

    private var gateway: FakeGateway!
    private var host: FakeHost!
    private var bridges: TmuxBridgeServer!
    private var client: TmuxControlClient!
    private var block = 100
    /// Commands answered so far; tmux replies in command order.
    private var answered = 0

    override func setUp() async throws {
        gateway = FakeGateway()
        host = FakeHost()
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("bt-\(UUID().uuidString.prefix(8)).sock")
        bridges = TmuxBridgeServer(socketPath: path)
        client = TmuxControlClient(gateway: gateway, host: host, bridges: bridges)
        client.options = { TmuxControlClient.Options() }
    }

    override func tearDown() async throws {
        client.gatewayExited()
        bridges.shutdown()
    }

    private func feed(_ lines: String...) {
        for line in lines { client.receive(Array(line.utf8)) }
    }

    /// Answers the oldest unanswered command with `lines`.
    private func reply(_ lines: String...) { reply(lines) }

    private func reply(_ lines: [String], error: Bool = false) {
        block += 1
        answered += 1
        client.receive(Array("%begin 0 \(block) 1".utf8))
        for line in lines { client.receive(Array(line.utf8)) }
        client.receive(Array("%\(error ? "error" : "end") 0 \(block) 1".utf8))
    }

    /// Answers every command sent so far (and those the answers send).
    private func settle() {
        while answered < gateway.commands.count { reply() }
    }

    /// Runs tmux's startup, answers `list-windows` with `windows` and lets
    /// every pane go live.
    private func attach(_ windows: String...) {
        feed("%begin 0 1 0", "%end 0 1 0", "%window-add @0", "%sessions-changed", "%session-changed $0 0")
        XCTAssertEqual(gateway.commands.count, 4)
        XCTAssertEqual(gateway.commands[0], "refresh-client -C 80x24")
        XCTAssertEqual(gateway.commands[1], "display -p '#{version}'")
        XCTAssertTrue(gateway.commands[2].hasPrefix("list-sessions -F"))
        XCTAssertTrue(gateway.commands[3].hasPrefix("list-windows -F"))
        reply()
        reply("3.6b")
        reply("0\t\(windows.count)\t1", "other\t1\t0")
        reply(windows)
        settle()
    }

    func testAttachOpensWindowsAsWorkspaces() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 0 zsh", "@1 0 b25d,80x24,0,0,2 %2 0 logs")
        XCTAssertEqual(host.opened.map(\.window), ["@0", "@1"])
        XCTAssertEqual(host.opened.map(\.name), ["zsh", "logs"])
        XCTAssertEqual(host.opened.map(\.focus), [true, false])
        let first = host.opened[0]
        XCTAssertEqual(Set(first.tree.leafIDs), Set(first.programs.keys))
        XCTAssertEqual(first.programs.count, 2)
        for program in first.programs.values {
            XCTAssertTrue(program.contains("--tmux-bridge"), program)
        }
        // Each pane captures its screen before going live.
        XCTAssertTrue(gateway.commands.contains("capture-pane -p -e -C -q -J -t %0 -S -1000"))
        XCTAssertTrue(gateway.commands.contains("capture-pane -p -e -C -q -J -t %2 -S -1000"))
        XCTAssertTrue(TmuxControlClient.owning(workspace: first.id) === client)
    }

    func testLayoutChangeAddsAndRemovesPanes() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let workspace = try XCTUnwrap(host.opened.first)
        let original = try XCTUnwrap(workspace.tree.leafIDs.first)

        feed("%layout-change @0 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,3} x *")
        let (id, split, programs) = try XCTUnwrap(host.layouts.last)
        XCTAssertEqual(id, workspace.id)
        XCTAssertEqual(split.leafIDs.count, 2)
        XCTAssertEqual(split.leafIDs.first, original)
        XCTAssertEqual(programs.count, 1)
        XCTAssertNotNil(programs[split.leafIDs[1]])

        feed("%layout-change @0 8205,80x24,0,0,3 x *")
        XCTAssertEqual(host.layouts.last?.1.leafIDs, [split.leafIDs[1]])
        XCTAssertEqual(host.layouts.last?.2.isEmpty, true)
    }

    func testSessionRenameDetachAndKill() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        XCTAssertEqual(client.label, "session 0")
        client.remoteHost = "web"
        feed("%session-renamed $0 work")
        XCTAssertEqual(client.label, "web: work")
        feed("%session-renamed $9 other")
        XCTAssertEqual(client.session, "work")

        client.renameSession("it's")
        XCTAssertEqual(gateway.commands.last, "rename-session -- 'it'\\''s'")

        // Detaching leaves the session to come back to.
        feed("%exit detached")
        XCTAssertTrue(client.canReattach)
        client.killSession()
        XCTAssertFalse(client.canReattach)
    }

    func testServerExitCannotReattach() {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        feed("%exit server exited")
        XCTAssertFalse(client.canReattach)
    }

    func testRenameAndClose() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let workspace = try XCTUnwrap(host.opened.first).id
        feed("%window-renamed @0 build")
        XCTAssertEqual(host.renamed.first?.0, workspace)
        XCTAssertEqual(host.renamed.first?.1, "build")
        feed("%window-close @0")
        XCTAssertEqual(host.closed, [workspace])
        XCTAssertNil(TmuxControlClient.owning(workspace: workspace))
        // A layout for a closed window is ignored.
        feed("%layout-change @0 8205,80x24,0,0,0 x *")
        XCTAssertTrue(host.layouts.isEmpty)
    }

    func testNewWindowIsLookedUpThenOpened() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        client.newWindow()
        XCTAssertEqual(gateway.commands.last, "new-window -P -F '#{window_id}'")
        reply("@5")
        feed("%window-add @5")
        XCTAssertTrue(try XCTUnwrap(gateway.commands.last).hasPrefix("display -p -t @5"))
        reply("@5 1 b25d,80x24,0,0,6 %6 0 new")
        XCTAssertEqual(host.opened.map(\.window), ["@0", "@5"])
        XCTAssertEqual(host.opened.last?.focus, true)
        settle()

        // A window another client made opens behind the current one.
        feed("%window-add @7")
        reply("@7 0 b25d,80x24,0,0,8 %8 0 theirs")
        XCTAssertEqual(host.opened.last?.window, "@7")
        XCTAssertEqual(host.opened.last?.focus, false)
    }

    func testSplitAndDetachCommands() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let pane = try XCTUnwrap(host.opened.first?.tree.leafIDs.first)
        client.split(pane: pane, toward: .right)
        XCTAssertEqual(gateway.commands.last, "split-window -h -t %0")
        client.split(pane: pane, toward: .up)
        XCTAssertEqual(gateway.commands.last, "split-window -v -b -t %0")
        client.split(pane: UUID(), toward: .down)
        XCTAssertEqual(gateway.commands.last, "split-window -v -b -t %0")
        client.detach()
        XCTAssertEqual(gateway.commands.last, "detach-client")
        client.newWindow()
        XCTAssertEqual(gateway.commands.last, "new-window -P -F '#{window_id}'")
        client.detach()
        XCTAssertEqual(gateway.commands.filter { $0 == "detach-client" }.count, 1)
    }

    func testDragCommandsMovePanes() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 0 zsh", "@1 0 b25d,80x24,0,0,2 %2 0 logs")
        let left = try XCTUnwrap(host.opened[0].tree.leafIDs.first)
        let right = try XCTUnwrap(host.opened[0].tree.leafIDs.last)
        let other = try XCTUnwrap(host.opened[1].tree.leafIDs.first)
        XCTAssertTrue(client.owns(pane: other))
        XCTAssertFalse(client.owns(pane: UUID()))

        client.join(pane: other, to: left, toward: .left, full: false)
        XCTAssertEqual(gateway.commands.last, "join-pane -h -b -s %2 -t %0")
        client.join(pane: other, to: right, toward: .down, full: true)
        XCTAssertEqual(gateway.commands.last, "join-pane -v -f -s %2 -t %1")
        client.swap(pane: left, with: right)
        XCTAssertEqual(gateway.commands.last, "swap-pane -s %0 -t %1")
        client.breakOut(pane: right)
        XCTAssertEqual(gateway.commands.last, "break-pane -P -F '#{window_id}' -s %1")
        let sent = gateway.commands.count
        client.join(pane: left, to: left, toward: .right, full: false)
        client.swap(pane: left, with: UUID())
        XCTAssertEqual(gateway.commands.count, sent)
    }

    func testPaneMovedToAnotherWindowIsRelinked() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 0 zsh", "@1 0 b25d,80x24,0,0,2 %2 0 logs")
        let moved = try XCTUnwrap(host.opened[0].tree.leafIDs.last)

        // join-pane %1 into @1: tmux may report the new window first.
        feed("%layout-change @1 8205,80x24,0,0{40x24,0,0,2,39x24,41,0,1} x *")
        let (workspace, tree, programs) = try XCTUnwrap(host.layouts.last)
        XCTAssertEqual(workspace, host.opened[1].id)
        XCTAssertEqual(tree.leafIDs.count, 2)
        XCTAssertFalse(tree.leafIDs.contains(moved))
        XCTAssertEqual(programs.count, 1)
        XCTAssertTrue(gateway.commands.contains("capture-pane -p -e -C -q -J -t %1 -S -1000"))

        feed("%layout-change @0 b25d,80x24,0,0,0 x *")
        XCTAssertEqual(host.layouts.last?.0, host.opened[0].id)
        XCTAssertEqual(host.layouts.last?.1.leafIDs.count, 1)
        // The old pane's bridge going away must not kill the moved pane.
        XCTAssertFalse(gateway.commands.contains("kill-pane -t %1"))
    }

    func testGatewayExitClosesEverything() throws {
        attach("@0 1 8205,80x24,0,0,0 zsh", "@1 0 b25d,80x24,0,0,1 %1 0 logs")
        client.gatewayExited()
        XCTAssertEqual(Set(host.closed), Set(host.opened.map(\.id)))
        for opened in host.opened { XCTAssertNil(TmuxControlClient.owning(workspace: opened.id)) }
    }

    func testCommandsBeforeStartWaitForSession() {
        client.newWindow()
        XCTAssertTrue(gateway.commands.isEmpty)
        feed("%begin 0 1 0", "%end 0 1 0", "%session-changed $0 0")
        XCTAssertEqual(gateway.commands.first, "new-window -P -F '#{window_id}'")
    }

    // MARK: - Focus, zoom, navigation

    func testFocusFollowsBothWays() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 0 zsh", "@1 0 b25d,80x24,0,0,2 %2 0 logs")
        let first = host.opened[0]
        let (left, right) = (first.tree.leafIDs[0], first.tree.leafIDs[1])
        let other = try XCTUnwrap(host.opened[1].tree.leafIDs.first)
        // Opening reports each window's active pane.
        XCTAssertEqual(host.focused.map(\.0), [left, other])
        let sent = gateway.commands.count

        // Boo to tmux; an unchanged focus sends nothing.
        client.focus(pane: left)
        XCTAssertEqual(gateway.commands.count, sent)
        client.focus(pane: right)
        XCTAssertEqual(gateway.commands.last, "select-pane -t %1")
        // %2 is already active in @1: only the window changes.
        client.focus(pane: other)
        XCTAssertEqual(Array(gateway.commands.suffix(2)), ["select-pane -t %1", "select-window -t @1"])
        client.focus(workspace: first.id)
        XCTAssertEqual(gateway.commands.last, "select-window -t @0")

        // tmux to Boo; the echo of Boo's own change is dropped.
        host.focused = []
        feed("%window-pane-changed @0 %1")
        XCTAssertTrue(host.focused.isEmpty)
        feed("%window-pane-changed @0 %0")
        XCTAssertEqual(host.focused.first?.0, left)
        XCTAssertEqual(host.focused.first?.1, first.id)
        feed("%session-window-changed $0 @1")
        XCTAssertEqual(host.selected, [host.opened[1].id])
        feed("%session-window-changed $0 @1", "%session-window-changed $5 @0")
        XCTAssertEqual(host.selected.count, 1)
    }

    func testZoomFollowsLayoutFlags() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %1 0 zsh")
        let workspace = host.opened[0]
        let right = workspace.tree.leafIDs[1]
        client.toggleZoom(pane: right)
        XCTAssertEqual(gateway.commands.last, "resize-pane -Z -t %1")
        feed("%layout-change @0 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} b25d,80x24,0,0,1 *Z")
        XCTAssertEqual(host.zooms.last?.0, workspace.id)
        XCTAssertEqual(host.zooms.last?.1, right)
        // The same flags again change nothing.
        feed("%layout-change @0 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} b25d,80x24,0,0,1 *Z")
        XCTAssertEqual(host.zooms.count, 1)
        feed("%layout-change @0 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} x *")
        XCTAssertEqual(host.zooms.count, 2)
        XCTAssertNil(host.zooms.last?.1)
    }

    func testAttachShowsZoomedWindowZoomed() {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 1 zsh")
        XCTAssertEqual(host.zooms.first?.1, host.opened[0].tree.leafIDs[0])
    }

    func testNavigationUsesTmux() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} %0 0 zsh")
        let left = host.opened[0].tree.leafIDs[0]
        client.focusPane(from: left, toward: .right)
        XCTAssertEqual(gateway.commands.last, "select-pane -R -t %0")
        client.focusPane(from: left, toward: .up)
        XCTAssertEqual(gateway.commands.last, "select-pane -U -t %0")
        client.cyclePane(from: left, by: 1)
        XCTAssertEqual(gateway.commands.last, "select-pane -t @0.+")
        client.cyclePane(from: left, by: -1)
        XCTAssertEqual(gateway.commands.last, "select-pane -t @0.-")
    }

    // MARK: - Windows and sessions

    func testRenameAndReorderWindows() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh", "@1 0 b25d,80x24,0,0,1 %1 0 logs")
        let (zsh, logs) = (host.opened[0].id, host.opened[1].id)
        let sent = gateway.commands.count
        client.renameWindow(workspace: zsh, to: " zsh ", after: 0)
        client.renameWindow(workspace: zsh, to: "", after: 0)
        XCTAssertEqual(gateway.commands.count, sent)
        client.renameWindow(workspace: zsh, to: "it's", after: 0)
        XCTAssertEqual(gateway.commands.last, "rename-window -t @0 -- 'it'\\''s'")

        client.reorder(logs, in: [logs, zsh])
        XCTAssertEqual(gateway.commands.last, "move-window -b -s @1 -t @0")
        client.reorder(zsh, in: [logs, UUID(), zsh])
        XCTAssertEqual(gateway.commands.last, "move-window -a -s @0 -t @1")
    }

    func testSessionsAndSwitchClient() {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        XCTAssertEqual(client.sessions.map(\.name), ["0", "other"])
        client.switchSession(to: "0")
        XCTAssertFalse(gateway.commands.last?.hasPrefix("switch-client") ?? false)
        client.switchSession(to: "other")
        XCTAssertEqual(gateway.commands.last, "switch-client -t 'other'")
        reply()
        feed("%sessions-changed")
        XCTAssertTrue(gateway.commands.last?.hasPrefix("list-sessions -F") ?? false)
        reply("0\t1\t1")
        XCTAssertEqual(client.sessions.map(\.name), ["0"])
    }

    func testLargeSessionAsksWhichWindowsToOpen() {
        client.options = { TmuxControlClient.Options(attachWindowLimit: 2) }
        host.choice = ["@0"]
        attach(
            "@0 0 8205,80x24,0,0,0 %0 0 a", "@1 0 8205,80x24,0,0,1 %1 0 b", "@2 1 8205,80x24,0,0,2 %2 0 c")
        XCTAssertEqual(host.asked, ["@0", "@1", "@2"])
        // The chosen windows and the current one open; the rest wait.
        XCTAssertEqual(host.opened.map(\.window), ["@0", "@2"])
        XCTAssertEqual(client.unopenedWindows.map(\.id), ["@1"])
        client.openWindow("@1")
        XCTAssertTrue(client.unopenedWindows.isEmpty)
        reply("@1 0 8205,80x24,0,0,1 %1 0 b")
        XCTAssertEqual(host.opened.last?.window, "@1")
        XCTAssertEqual(host.opened.last?.focus, true)
    }

    // MARK: - Subscriptions, flow control, errors, buffers

    func testControlFeaturesNeedTmux32() {
        client.options = { TmuxControlClient.Options(pauseAfterSeconds: 3) }
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        XCTAssertTrue(gateway.commands.contains("refresh-client -B 'boo-cwd:%*:#{pane_current_path}'"))
        XCTAssertTrue(gateway.commands.contains("refresh-client -B 'boo-cmd:%*:#{pane_current_command}'"))
        XCTAssertTrue(gateway.commands.contains("refresh-client -f pause-after=3"))
    }

    func testOldTmuxGetsNoSubscriptions() {
        feed("%begin 0 1 0", "%end 0 1 0", "%session-changed $0 0")
        reply()
        reply("3.1c")
        settle()
        XCTAssertFalse(gateway.commands.contains { $0.hasPrefix("refresh-client -B") })
    }

    func testSubscriptionsFeedPanes() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let pane = try XCTUnwrap(host.opened.first?.tree.leafIDs.first)
        feed("%subscription-changed boo-cwd $0 @0 0 %0 : /tmp/my dir")
        feed("%subscription-changed boo-cmd $0 @0 0 %0 : vim")
        feed("%subscription-changed boo-cmd $0 @0 0 %9 : top")
        XCTAssertEqual(host.changes.count, 2)
        XCTAssertEqual(host.changes[0].0, pane)
        XCTAssertEqual(host.changes[0].1, "/tmp/my dir")
        XCTAssertEqual(host.changes[1].2, "vim")
    }

    func testPauseShowsBarAndContinueRedraws() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let pane = try XCTUnwrap(host.opened.first?.tree.leafIDs.first)
        feed("%pause %0")
        XCTAssertEqual(host.paused.map(\.1), [true])
        client.unpause(pane: pane)
        XCTAssertEqual(gateway.commands.last, "refresh-client -A '%0:continue'")
        feed("%continue %0")
        XCTAssertEqual(host.paused.last?.0, pane)
        XCTAssertEqual(host.paused.last?.1, false)
        // Output sent while paused is lost: the screen is captured again.
        XCTAssertEqual(gateway.commands.last, "capture-pane -p -e -C -q -J -t %0")
    }

    func testAutoUnpause() {
        client.options = { TmuxControlClient.Options(pauseAfterSeconds: 2, autoUnpause: true) }
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        feed("%pause %0")
        XCTAssertEqual(gateway.commands.last, "refresh-client -A '%0:continue'")
        XCTAssertTrue(host.paused.isEmpty)
    }

    func testErrorsShowUnlessQuiet() throws {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        let pane = try XCTUnwrap(host.opened.first?.tree.leafIDs.first)
        client.split(pane: pane, toward: .right)
        reply(["no space for new pane"], error: true)
        XCTAssertEqual(host.errors, ["tmux split-window: no space for new pane"])
        client.focusPane(from: pane, toward: .left)
        reply(["no pane"], error: true)
        XCTAssertEqual(host.errors.count, 1)

        var output: TmuxControlClient.Reply?
        client.run("show -g status\n") { output = $0 }
        XCTAssertEqual(gateway.commands.last, "show -g status")
        reply(["status on"])
        XCTAssertEqual(output?.text, ["status on"])
        XCTAssertEqual(output?.isError, false)
    }

    func testPasteBufferMirror() {
        attach("@0 1 8205,80x24,0,0,0 %0 0 zsh")
        feed("%paste-buffer-changed buffer0")
        XCTAssertFalse(gateway.commands.last?.hasPrefix("show-buffer") ?? false)
        client.options = { TmuxControlClient.Options(mirrorPasteBuffer: true) }
        feed("%paste-buffer-changed buffer0")
        XCTAssertEqual(gateway.commands.last, "show-buffer -b 'buffer0'")
        reply("one", "two")
        XCTAssertEqual(host.clipboard, ["one\ntwo"])
    }
}
