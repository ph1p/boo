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
    }

    private var gateway: FakeGateway!
    private var host: FakeHost!
    private var bridges: TmuxBridgeServer!
    private var client: TmuxControlClient!
    private var block = 100

    override func setUp() async throws {
        gateway = FakeGateway()
        host = FakeHost()
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("bt-\(UUID().uuidString.prefix(8)).sock")
        bridges = TmuxBridgeServer(socketPath: path)
        client = TmuxControlClient(gateway: gateway, host: host, bridges: bridges)
    }

    override func tearDown() async throws {
        client.gatewayExited()
        bridges.shutdown()
    }

    private func feed(_ lines: String...) {
        for line in lines { client.receive(Array(line.utf8)) }
    }

    /// Answers the oldest unanswered command with `lines`.
    private func reply(_ lines: String...) {
        block += 1
        client.receive(Array("%begin 0 \(block) 1".utf8))
        for line in lines { client.receive(Array(line.utf8)) }
        client.receive(Array("%end 0 \(block) 1".utf8))
    }

    /// Runs tmux's startup and answers `list-windows` with `windows`.
    private func attach(_ windows: String...) {
        feed("%begin 0 1 0", "%end 0 1 0", "%window-add @0", "%sessions-changed", "%session-changed $0 0")
        XCTAssertEqual(gateway.commands.count, 2)
        XCTAssertEqual(gateway.commands[0], "refresh-client -C 80x24")
        XCTAssertTrue(gateway.commands[1].hasPrefix("list-windows -F"))
        reply()
        block += 1
        client.receive(Array("%begin 0 \(block) 1".utf8))
        for line in windows { client.receive(Array(line.utf8)) }
        client.receive(Array("%end 0 \(block) 1".utf8))
    }

    func testAttachOpensWindowsAsWorkspaces() throws {
        attach("@0 1 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} zsh", "@1 0 b25d,80x24,0,0,2 logs")
        XCTAssertEqual(host.opened.map(\.window), ["@0", "@1"])
        XCTAssertEqual(host.opened.map(\.name), ["tmux: zsh", "tmux: logs"])
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
        attach("@0 1 8205,80x24,0,0,0 zsh")
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

    func testRenameAndClose() throws {
        attach("@0 1 8205,80x24,0,0,0 zsh")
        let workspace = try XCTUnwrap(host.opened.first).id
        feed("%window-renamed @0 build")
        XCTAssertEqual(host.renamed.first?.0, workspace)
        XCTAssertEqual(host.renamed.first?.1, "tmux: build")
        feed("%window-close @0")
        XCTAssertEqual(host.closed, [workspace])
        XCTAssertNil(TmuxControlClient.owning(workspace: workspace))
        // A layout for a closed window is ignored.
        feed("%layout-change @0 8205,80x24,0,0,0 x *")
        XCTAssertTrue(host.layouts.isEmpty)
    }

    func testNewWindowIsLookedUpThenOpened() throws {
        attach("@0 1 8205,80x24,0,0,0 zsh")
        client.newWindow()
        XCTAssertEqual(gateway.commands.last, "new-window")
        feed("%window-add @5")
        XCTAssertTrue(try XCTUnwrap(gateway.commands.last).hasPrefix("display -p -t @5"))
        // Replies come in command order: capture-pane, new-window, display (@5);
        // the cursor query the capture reply sends goes after them.
        reply()
        reply()
        reply("@5 1 b25d,80x24,0,0,6 new")
        XCTAssertEqual(host.opened.map(\.window), ["@0", "@5"])
        XCTAssertEqual(host.opened.last?.focus, true)
    }

    func testSplitAndDetachCommands() throws {
        attach("@0 1 8205,80x24,0,0,0 zsh")
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
        XCTAssertEqual(gateway.commands.last, "new-window")
        client.detach()
        XCTAssertEqual(gateway.commands.filter { $0 == "detach-client" }.count, 1)
    }

    func testGatewayExitClosesEverything() throws {
        attach("@0 1 8205,80x24,0,0,0 zsh", "@1 0 b25d,80x24,0,0,1 logs")
        client.gatewayExited()
        XCTAssertEqual(Set(host.closed), Set(host.opened.map(\.id)))
        for opened in host.opened { XCTAssertNil(TmuxControlClient.owning(workspace: opened.id)) }
    }

    func testCommandsBeforeStartWaitForSession() {
        client.newWindow()
        XCTAssertTrue(gateway.commands.isEmpty)
        feed("%begin 0 1 0", "%end 0 1 0", "%session-changed $0 0")
        XCTAssertEqual(gateway.commands.first, "new-window")
    }
}
