import Combine
import XCTest

@testable import Boo

/// Tests for process name extraction from terminal titles and socket-based
/// AI agent detection. Covers:
/// - Path titles rejected as process names
/// - Normal process extraction preserved
/// - Socket registration overrides title heuristics
/// - Title-only detection (without socket) follows extractProcessName directly
@MainActor
final class AIProcessDetectionTests: XCTestCase {

    private var bridge: TerminalBridge!
    private var registry: PluginRegistry!
    private var debug: DebugPlugin!
    private var cancellables: Set<AnyCancellable>!
    private let paneID = UUID()
    private let workspaceID = UUID()

    override func setUp() {
        super.setUp()
        cancellables = []
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        registry = PluginRegistry()
        debug = DebugPlugin()
        registry.register(debug)

        bridge.events.sink { [weak self] event in
            guard let self else { return }
            let ctx = self.currentContext()
            switch event {
            case .directoryChanged(let path):
                self.registry.notifyCwdChanged(newPath: path, context: ctx)
                self.registry.runCycle(baseContext: ctx, reason: .cwdChanged)
            case .processChanged(let name):
                self.registry.notifyProcessChanged(name: name, context: ctx)
                self.registry.runCycle(baseContext: ctx, reason: .processChanged)
            case .titleChanged:
                self.registry.runCycle(baseContext: ctx, reason: .titleChanged)
            default:
                break
            }
        }.store(in: &cancellables)
    }

    override func tearDown() {
        BooSocketServer.shared.processes.removeAll()
        cancellables = nil
        bridge = nil
        registry = nil
        debug = nil
        super.tearDown()
    }

    private func currentContext() -> TerminalContext {
        TerminalContext(
            terminalID: bridge.state.tabID,
            cwd: bridge.state.workingDirectory,
            remoteSession: bridge.state.remoteSession,
            gitContext: nil,
            processName: bridge.state.foregroundProcess,
            paneCount: 1,
            tabCount: 1
        )
    }

    private func processEvents() -> [DebugPlugin.LogEntry] {
        debug.entries.filter { $0.event == "processChanged" }
    }

    // MARK: - extractProcessName: Path Rejection

    func testPathTildeSlashReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "~/dev/project"), "")
    }

    func testPathAbsoluteReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "/Users/testuser/dev/project"), "")
    }

    func testPathEllipsisReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "…/dev/telis/e2e-playwright-starter"), "")
    }

    func testPathTildeAloneReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "~"), "")
    }

    func testPathDotSlashReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "./run.sh"), "")
    }

    func testPathDotDotSlashReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "../other/project"), "")
    }

    func testPathWithColonReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "~/dev/project: info"), "")
    }

    func testPathAbsoluteWithColonReturnsEmpty() {
        XCTAssertEqual(
            TerminalBridge.extractProcessName(from: "/Users/testuser/dev/telis/e2e-playwright-starter"), "")
    }

    func testPathWithSpacesReturnsEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "~/Library/Application Support"), "")
    }

    // MARK: - extractProcessName: Normal processes

    func testVimDetected() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "vim file.txt"), "vim")
    }

    func testNodeDetected() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "node server.js"), "node")
    }

    func testPython3Detected() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "python3 script.py"), "python3")
    }

    func testShellEmpty() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "zsh"), "")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "bash"), "")
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "fish"), "")
    }

    func testClaudeCodeTitleDetected() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "✳ Claude Code"), "claude")
    }

    func testCodexTitleDetected() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "Codex CLI"), "codex")
    }

    func testRemoteUserHostDetected() {
        XCTAssertEqual(
            TerminalBridge.extractProcessName(from: "user@remote-server: ~/dir"), "user@remote-server")
    }

    func testSSHCommandNotAPath() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "ssh user@host"), "ssh")
    }

    func testGitCommandNotAPath() {
        XCTAssertEqual(TerminalBridge.extractProcessName(from: "git status"), "git")
    }

    // MARK: - Title-only detection (no socket): process follows title

    func testTitleSetsAndClears() {
        bridge.handleTitleChange(title: "✳ Claude Code", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "vim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
    }

    func testPathTitleClears() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "~/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
    }

    func testSpinnerTitleKeepsClaude() {
        bridge.handleTitleChange(title: "✳ Claude Code", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Spinner titles still match "claude" via matchTitle
        bridge.handleTitleChange(title: "⠂ General coding assistance", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")
    }

    func testShellTitleClears() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
    }

    // MARK: - Socket-based: process set via reevaluateSocketProcess

    func testSocketAgentSetViaReeval() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])

        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Title changes do NOT affect foregroundProcess
        bridge.handleTitleChange(title: "~/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "⠂ General coding assistance", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testSocketSurvivesTitleChanges() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Title changes don't downgrade socket-registered process
        bridge.handleTitleChange(title: "⠂ General coding assistance", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testSocketAgentClearsOnUnregister() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])

        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Agent exits — socket cleared
        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        bridge.monitor.untrack(paneID: paneID)
    }

    // MARK: - Full E2E: Socket-based Claude session

    func testFullClaudeSessionWithSocket() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())

        // 1. cd to project
        bridge.handleDirectoryChange(path: "/Users/dev/project", paneID: paneID)

        // 2. No agent yet — process stays empty
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        // 3. Agent registers via socket
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // 4. All title changes — agent stays (title doesn't affect process)
        for title in ["⠂ Thinking", "~/dev/project", "zsh", "⠐ Building...", "/Users/dev/project"] {
            bridge.handleTitleChange(title: title, paneID: paneID)
            XCTAssertEqual(
                bridge.state.foregroundProcess, "claude",
                "Socket agent must survive title '\(title)'")
        }

        // 5. Agent exits (sweep detects dead PID)
        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        // Verify plugin log
        let procEvents = processEvents()
        let starts = procEvents.filter { $0.detail.contains("name=claude") }
        let clears = procEvents.filter { $0.detail.contains("name=(empty)") }
        XCTAssertGreaterThanOrEqual(starts.count, 1)
        XCTAssertGreaterThanOrEqual(clears.count, 1)

        bridge.monitor.untrack(paneID: paneID)
    }

    // MARK: - Sequential AI sessions with socket

    func testSequentialSocketSessions() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())

        for name in ["claude", "codex", "opencode"] {
            BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
                pid: myPid, name: name, category: "ai", registeredAt: Date(), metadata: [:])
            bridge.reevaluateSocketProcess()
            XCTAssertEqual(bridge.state.foregroundProcess, name)

            BooSocketServer.shared.processes.removeAll()
            bridge.reevaluateSocketProcess()
            XCTAssertEqual(bridge.state.foregroundProcess, "")
        }

        bridge.monitor.untrack(paneID: paneID)
    }

    // MARK: - CWD changes don't affect socket process

    func testSocketProcessSurvivesCwdChanges() {
        let myPid = getpid()
        bridge.monitor.track(paneID: paneID, shellPID: getppid())
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()

        bridge.handleDirectoryChange(path: "/Users/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleDirectoryChange(path: "/Users/dev/other", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.monitor.untrack(paneID: paneID)
    }
}
