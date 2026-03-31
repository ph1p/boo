import Combine
import XCTest

@testable import Boo

// MARK: - BooSocketServer Unit Tests

@MainActor
final class BooSocketServerTests: XCTestCase {

    func testSocketPathInBooDir() {
        let server = BooSocketServer.shared
        XCTAssertTrue(server.socketPath.hasPrefix(BooPaths.configDir))
        XCTAssertTrue(server.socketPath.hasSuffix("boo.sock"))
    }

    func testDirectProcessRegistration() {
        let server = BooSocketServer.shared
        let pid = getpid()

        server.processes[pid] = BooSocketServer.ProcessStatus(
            pid: pid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])

        XCTAssertTrue(server.hasActiveProcesses)
        XCTAssertEqual(server.processes[pid]?.name, "claude")
        XCTAssertEqual(server.processes[pid]?.category, "ai")

        server.processes.removeAll()
        XCTAssertFalse(server.hasActiveProcesses)
    }

    func testActiveProcessFindsDescendant() {
        let server = BooSocketServer.shared
        let myPid = getpid()
        let parentPid = getppid()

        server.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "codex", category: "ai", registeredAt: Date(), metadata: [:])

        let status = server.activeProcess(shellPID: parentPid)
        XCTAssertEqual(status?.name, "codex")

        server.processes.removeAll()
    }

    func testActiveProcessFiltersByCategory() {
        let server = BooSocketServer.shared
        let myPid = getpid()
        let parentPid = getppid()

        server.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "webpack", category: "build", registeredAt: Date(), metadata: [:])

        // Should find when no category filter
        XCTAssertNotNil(server.activeProcess(shellPID: parentPid))

        // Should find when matching category
        XCTAssertNotNil(server.activeProcess(shellPID: parentPid, category: "build"))

        // Should NOT find when different category
        XCTAssertNil(server.activeProcess(shellPID: parentPid, category: "ai"))

        server.processes.removeAll()
    }

    func testActiveProcessNilWhenEmpty() {
        let server = BooSocketServer.shared
        server.processes.removeAll()
        XCTAssertNil(server.activeProcess(shellPID: getppid()))
    }

    func testMultipleProcesses() {
        let server = BooSocketServer.shared
        let pid1 = getpid()

        server.processes[pid1] = BooSocketServer.ProcessStatus(
            pid: pid1, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        server.processes[pid1 + 1] = BooSocketServer.ProcessStatus(
            pid: pid1 + 1, name: "webpack", category: "build", registeredAt: Date(), metadata: [:])

        XCTAssertEqual(server.processes.count, 2)
        XCTAssertEqual(server.processes[pid1]?.name, "claude")
        XCTAssertEqual(server.processes[pid1 + 1]?.name, "webpack")

        server.processes.removeAll()
    }

    func testProcessMetadata() {
        let server = BooSocketServer.shared
        let pid = getpid()

        server.processes[pid] = BooSocketServer.ProcessStatus(
            pid: pid, name: "jest", category: "test",
            registeredAt: Date(), metadata: ["suite": "unit", "coverage": "true"])

        XCTAssertEqual(server.processes[pid]?.metadata["suite"], "unit")
        XCTAssertEqual(server.processes[pid]?.metadata["coverage"], "true")

        server.processes.removeAll()
    }

}

// MARK: - Socket Protocol Integration Tests

@MainActor
final class BooSocketProtocolTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BooSocketServer.shared.start()
        Thread.sleep(forTimeInterval: 0.5)
    }

    override func tearDown() {
        BooSocketServer.shared.stop()
        Thread.sleep(forTimeInterval: 0.2)
        super.tearDown()
    }

    private func sendCommand(_ json: String) -> String? {
        let path = BooSocketServer.shared.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strlcpy(dest, ptr, 104)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let msg = json + "\n"
        _ = msg.withCString { write(fd, $0, strlen($0)) }
        Thread.sleep(forTimeInterval: 0.1)

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testSetAndClearStatus() {
        let pid = getpid()

        let setResp = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"claude","category":"ai"}
            """)
        XCTAssertTrue(setResp?.contains("\"ok\":true") ?? false)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.name, "claude")
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "ai")

        let clearResp = sendCommand(
            """
            {"cmd":"clear_status","pid":\(pid)}
            """)
        XCTAssertTrue(clearResp?.contains("\"ok\":true") ?? false)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(BooSocketServer.shared.processes[pid])
    }

    func testSetStatusWithMetadata() {
        let pid = getpid()

        let resp = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"jest","category":"test","metadata":{"suite":"e2e"}}
            """)
        XCTAssertTrue(resp?.contains("\"ok\":true") ?? false)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.metadata["suite"], "e2e")

        _ = sendCommand(
            """
            {"cmd":"clear_status","pid":\(pid)}
            """)
    }

    func testSetStatusRejectsDeadPID() {
        let resp = sendCommand(
            """
            {"cmd":"set_status","pid":99999999,"name":"fake","category":"ai"}
            """)
        XCTAssertTrue(resp?.contains("not found") ?? false)
    }

    func testListStatus() {
        let pid = getpid()
        _ = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"opencode","category":"ai"}
            """)
        Thread.sleep(forTimeInterval: 0.2)

        let resp = sendCommand(
            """
            {"cmd":"list_status"}
            """)
        XCTAssertTrue(resp?.contains("opencode") ?? false)
        XCTAssertTrue(resp?.contains("ai") ?? false)

        _ = sendCommand(
            """
            {"cmd":"clear_status","pid":\(pid)}
            """)
    }

    func testInvalidJSON() {
        let resp = sendCommand("not json")
        XCTAssertTrue(resp?.contains("invalid") ?? false)
    }

    func testUnknownCommand() {
        let resp = sendCommand(
            """
            {"cmd":"magic_spell"}
            """)
        XCTAssertTrue(resp?.contains("unknown") ?? false)
    }

    func testDefaultCategoryIsUnknown() {
        let pid = getpid()
        _ = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"myprocess"}
            """)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "unknown")

        _ = sendCommand(
            """
            {"cmd":"clear_status","pid":\(pid)}
            """)
    }
}

// MARK: - Bridge Integration Tests

@MainActor
final class BooSocketBridgeTests: XCTestCase {

    private var bridge: TerminalBridge!
    private var cancellables: Set<AnyCancellable>!
    private let paneID = UUID()
    private let workspaceID = UUID()

    override func setUp() {
        super.setUp()
        cancellables = []
        bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
    }

    override func tearDown() {
        BooSocketServer.shared.processes.removeAll()
        cancellables = nil
        bridge = nil
        super.tearDown()
    }

    func testReevaluateWithRegisteredProcess() {
        let myPid = getpid()
        let parentPid = getppid()

        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.monitor.track(paneID: paneID, shellPID: parentPid)

        var events: [TerminalEvent] = []
        bridge.events.sink { events.append($0) }.store(in: &cancellables)

        bridge.reevaluateSocketProcess()

        XCTAssertEqual(bridge.state.foregroundProcess, "claude")
        XCTAssertTrue(events.contains(.processChanged(name: "claude")))

        bridge.monitor.untrack(paneID: paneID)
    }

    func testReevaluateClearsWhenUnregistered() {
        let myPid = getpid()
        let parentPid = getppid()

        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.monitor.track(paneID: paneID, shellPID: parentPid)
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testSocketSurvivesTitleChanges() {
        let myPid = getpid()
        let parentPid = getppid()

        bridge.monitor.track(paneID: paneID, shellPID: parentPid)
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Title changes never affect foreground process
        bridge.handleTitleChange(title: "~/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testNonAICategoryAlsoWorks() {
        let myPid = getpid()
        let parentPid = getppid()

        bridge.monitor.track(paneID: paneID, shellPID: parentPid)
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "webpack", category: "build", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "webpack")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testTitleSetsAndClears() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "vim")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "")
    }

    func testSocketProcessReplacedByNewRegistration() {
        let myPid = getpid()
        let parentPid = getppid()

        bridge.monitor.track(paneID: paneID, shellPID: parentPid)

        // First registration
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // Replace with different process
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "codex", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "codex")

        bridge.monitor.untrack(paneID: paneID)
    }

    func testSocketProcessSurvivesTitleFlood() {
        let myPid = getpid()
        let parentPid = getppid()

        bridge.monitor.track(paneID: paneID, shellPID: parentPid)
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()

        // Title changes never affect foreground process
        let titles = [
            "~/dev/project", "/Users/phlp/project", "…/project",
            "⠂ Thinking", "⠐ Building...", "zsh", "bash",
            "node server.js", "vim file.txt", "~/other"
        ]
        for title in titles {
            bridge.handleTitleChange(title: title, paneID: paneID)
            XCTAssertEqual(
                bridge.state.foregroundProcess, "claude",
                "Socket process should survive title '\(title)'")
        }

        bridge.monitor.untrack(paneID: paneID)
    }
}

// MARK: - Plugin Command Handler Tests

@MainActor
final class BooSocketPluginHandlerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BooSocketServer.shared.start()
        Thread.sleep(forTimeInterval: 0.5)
    }

    override func tearDown() {
        BooSocketServer.shared.stop()
        Thread.sleep(forTimeInterval: 0.2)
        super.tearDown()
    }

    private func sendCommand(_ json: String) -> String? {
        let path = BooSocketServer.shared.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strlcpy(dest, ptr, 104)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let msg = json + "\n"
        _ = msg.withCString { write(fd, $0, strlen($0)) }
        Thread.sleep(forTimeInterval: 0.1)

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testCustomPluginHandler() {
        var received: [String: Any]?
        BooSocketServer.shared.registerHandler(namespace: "myplugin") { json in
            received = json
            return ["ok": true, "echo": json["data"] ?? "none"]
        }

        let resp = sendCommand(
            """
            {"cmd":"myplugin.refresh","data":"hello"}
            """)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(resp?.contains("\"ok\":true") ?? false)
        XCTAssertEqual(received?["cmd"] as? String, "myplugin.refresh")
        XCTAssertEqual(received?["data"] as? String, "hello")
    }

    func testNamespacedCommandRouting() {
        var gitHandled = false
        var dockerHandled = false

        BooSocketServer.shared.registerHandler(namespace: "git") { _ in
            gitHandled = true
            return ["ok": true]
        }
        BooSocketServer.shared.registerHandler(namespace: "docker") { _ in
            dockerHandled = true
            return ["ok": true]
        }

        _ = sendCommand(
            """
            {"cmd":"git.status"}
            """)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(gitHandled)
        XCTAssertFalse(dockerHandled)

        _ = sendCommand(
            """
            {"cmd":"docker.list"}
            """)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(dockerHandled)
    }

    func testUnregisteredNamespaceReturnsError() {
        let resp = sendCommand(
            """
            {"cmd":"nonexistent.action"}
            """)
        XCTAssertTrue(resp?.contains("unknown") ?? false)
    }

    func testMultipleCategories() {
        let pid = getpid()

        _ = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"jest","category":"test"}
            """)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "test")

        // Replace with different category
        _ = sendCommand(
            """
            {"cmd":"set_status","pid":\(pid),"name":"jest","category":"build"}
            """)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "build")

        _ = sendCommand(
            """
            {"cmd":"clear_status","pid":\(pid)}
            """)
    }

    func testMultipleProcessesDifferentCategories() {
        let pid1 = getpid()
        let parentPid = getppid()

        // Register two processes
        BooSocketServer.shared.processes[pid1] = BooSocketServer.ProcessStatus(
            pid: pid1, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        BooSocketServer.shared.processes[pid1 + 1] = BooSocketServer.ProcessStatus(
            pid: pid1 + 1, name: "webpack", category: "build", registeredAt: Date(), metadata: [:])

        // Filter by category
        let ai = BooSocketServer.shared.activeProcess(shellPID: parentPid, category: "ai")
        XCTAssertEqual(ai?.name, "claude")

        // Build category PID is likely not a real descendant, so may be nil
        let any = BooSocketServer.shared.activeProcess(shellPID: parentPid)
        XCTAssertNotNil(any, "Should find at least one descendant process")

        BooSocketServer.shared.processes.removeAll()
    }
}

// MARK: - Full E2E: Socket + Bridge + DebugPlugin

@MainActor
final class BooSocketFullE2ETests: XCTestCase {

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
            let ctx = TerminalContext(
                terminalID: self.bridge.state.tabID,
                cwd: self.bridge.state.workingDirectory,
                remoteSession: nil, gitContext: nil,
                processName: self.bridge.state.foregroundProcess,
                paneCount: 1, tabCount: 1
            )
            switch event {
            case .processChanged(let name):
                self.registry.notifyProcessChanged(name: name, context: ctx)
                self.registry.runCycle(baseContext: ctx, reason: .processChanged)
            case .titleChanged:
                self.registry.runCycle(baseContext: ctx, reason: .titleChanged)
            case .directoryChanged(let path):
                self.registry.notifyCwdChanged(newPath: path, context: ctx)
                self.registry.runCycle(baseContext: ctx, reason: .cwdChanged)
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

    private func processEvents() -> [DebugPlugin.LogEntry] {
        debug.entries.filter { $0.event == "processChanged" }
    }

    /// Full scenario: cd to project → agent registers via socket → dynamic titles →
    /// agent unregisters → shell resumes. All verified through DebugPlugin log.
    func testSocketAgentFullLifecycleE2E() {
        let myPid = getpid()
        let parentPid = getppid()
        bridge.monitor.track(paneID: paneID, shellPID: parentPid)

        // 1. cd to project
        bridge.handleDirectoryChange(path: "/Users/dev/project", paneID: paneID)

        // 2. Shell sets path title
        bridge.handleTitleChange(title: "~/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        // 3. Agent registers via socket
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // 4. Title changes to various things — agent stays
        bridge.handleTitleChange(title: "⠂ Thinking", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(
            bridge.state.foregroundProcess, "claude",
            "Socket agent survives shell title")

        bridge.handleTitleChange(title: "/Users/dev/project", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // 5. Agent unregisters (process exits, sweep fires)
        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        // 6. Verify DebugPlugin saw the lifecycle
        let procEvents = processEvents()
        let starts = procEvents.filter { $0.detail.contains("name=claude") }
        let clears = procEvents.filter { $0.detail.contains("name=(empty)") }
        XCTAssertGreaterThanOrEqual(starts.count, 1)
        XCTAssertGreaterThanOrEqual(clears.count, 1)

        bridge.monitor.untrack(paneID: paneID)
    }

    /// Build tool registers, does its thing, unregisters.
    func testBuildToolE2E() {
        let myPid = getpid()
        let parentPid = getppid()
        bridge.monitor.track(paneID: paneID, shellPID: parentPid)

        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "webpack", category: "build",
            registeredAt: Date(), metadata: ["mode": "production"])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "webpack")

        // Title changes don't affect it
        bridge.handleTitleChange(title: "zsh", paneID: paneID)
        XCTAssertEqual(bridge.state.foregroundProcess, "webpack")

        // Build completes, unregisters
        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        bridge.monitor.untrack(paneID: paneID)
    }

    /// Sequential registrations of different categories.
    func testSequentialDifferentCategories() {
        let myPid = getpid()
        let parentPid = getppid()
        bridge.monitor.track(paneID: paneID, shellPID: parentPid)

        // AI agent
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "claude")

        // AI exits, build starts
        BooSocketServer.shared.processes.removeAll()
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "cargo", category: "build", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "cargo")

        // Build exits, test starts
        BooSocketServer.shared.processes.removeAll()
        BooSocketServer.shared.processes[myPid] = BooSocketServer.ProcessStatus(
            pid: myPid, name: "jest", category: "test", registeredAt: Date(), metadata: [:])
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "jest")

        // All done
        BooSocketServer.shared.processes.removeAll()
        bridge.reevaluateSocketProcess()
        XCTAssertEqual(bridge.state.foregroundProcess, "")

        bridge.monitor.untrack(paneID: paneID)
    }
}
