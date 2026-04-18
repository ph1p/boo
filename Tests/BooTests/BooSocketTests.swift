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
            pid: myPid, name: "claude", category: "ai", registeredAt: Date(), metadata: [:])

        let status = server.activeProcess(shellPID: parentPid)
        XCTAssertEqual(status?.name, "claude")

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
final class BooSocketProtocolTests: BooSocketIntegrationTestCase {

    private func roundTrip(_ command: [String: Any]) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(command: command)
        }
    }

    private func roundTrip(rawJSON: String) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(rawJSON: rawJSON)
        }
    }

    func testSetAndClearStatus() throws {
        let pid = getpid()

        let setResponse = try roundTrip(["cmd": "set_status", "pid": pid, "name": "claude", "category": "ai"])
        XCTAssertEqual(setResponse["ok"] as? Bool, true)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.name, "claude")
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "ai")

        let clearResponse = try roundTrip(["cmd": "clear_status", "pid": pid])
        XCTAssertEqual(clearResponse["ok"] as? Bool, true)
        XCTAssertNil(BooSocketServer.shared.processes[pid])
    }

    func testSetStatusWithMetadata() throws {
        let pid = getpid()

        let response = try roundTrip(
            [
                "cmd": "set_status",
                "pid": pid,
                "name": "jest",
                "category": "test",
                "metadata": ["suite": "e2e"]
            ])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.metadata["suite"], "e2e")

        _ = try roundTrip(["cmd": "clear_status", "pid": pid])
    }

    func testSetStatusRejectsDeadPID() throws {
        let response = try roundTrip(
            ["cmd": "set_status", "pid": 99_999_999, "name": "fake", "category": "ai"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String)?.contains("not found") ?? false)
    }

    func testListStatus() throws {
        let pid = getpid()
        _ = try roundTrip(["cmd": "set_status", "pid": pid, "name": "opencode", "category": "ai"])

        let response = try roundTrip(["cmd": "list_status"])
        XCTAssertEqual(response["ok"] as? Bool, true)

        let processes = try XCTUnwrap(response["processes"] as? [[String: Any]])
        let entry = processes.first { ($0["pid"] as? Int) == Int(pid) }
        XCTAssertEqual(entry?["name"] as? String, "opencode")
        XCTAssertEqual(entry?["category"] as? String, "ai")

        _ = try roundTrip(["cmd": "clear_status", "pid": pid])
    }

    func testInvalidJSON() throws {
        let response = try roundTrip(rawJSON: "not json")
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "invalid json")
    }

    func testUnknownCommand() throws {
        let response = try roundTrip(["cmd": "magic_spell"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String)?.contains("unknown command") ?? false)
    }

    func testDefaultCategoryIsUnknown() throws {
        let pid = getpid()
        let response = try roundTrip(["cmd": "set_status", "pid": pid, "name": "myprocess"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "unknown")

        _ = try roundTrip(["cmd": "clear_status", "pid": pid])
    }
}

// MARK: - Bridge Integration Tests

@MainActor
final class BooSocketBridgeTests: XCTestCase {

    nonisolated(unsafe) private var bridge: TerminalBridge!
    nonisolated(unsafe) private var cancellables: Set<AnyCancellable>!
    private let paneID = UUID()
    private let workspaceID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            cancellables = []
            bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            BooSocketServer.shared.processes.removeAll()
            cancellables = nil
            bridge = nil
        }
        try await super.tearDown()
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
            "~/dev/project", "/Users/testuser/project", "…/project",
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
final class BooSocketPluginHandlerTests: BooSocketIntegrationTestCase {

    private func roundTrip(_ json: [String: Any]) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(command: json)
        }
    }

    private func roundTrip(rawJSON: String) throws -> [String: Any] {
        try withBooSocketClient { client in
            try client.roundTrip(rawJSON: rawJSON)
        }
    }

    func testCustomPluginHandler() throws {
        nonisolated(unsafe) var received: [String: Any]?
        BooSocketServer.shared.registerHandler(namespace: "myplugin") { json in
            received = json
            return ["ok": true, "echo": json["data"] ?? "none"]
        }

        let resp = try roundTrip(
            rawJSON: """
                {"cmd":"myplugin.refresh","data":"hello"}
                """)

        XCTAssertEqual(resp["ok"] as? Bool, true)
        BooSocketTestSupport.waitUntil { received != nil }
        XCTAssertEqual(received?["cmd"] as? String, "myplugin.refresh")
        XCTAssertEqual(received?["data"] as? String, "hello")
    }

    func testNamespacedCommandRouting() throws {
        nonisolated(unsafe) var gitHandled = false
        nonisolated(unsafe) var dockerHandled = false

        BooSocketServer.shared.registerHandler(namespace: "git") { _ in
            gitHandled = true
            return ["ok": true]
        }
        BooSocketServer.shared.registerHandler(namespace: "docker") { _ in
            dockerHandled = true
            return ["ok": true]
        }

        _ = try roundTrip(
            rawJSON: """
                {"cmd":"git.status"}
                """)
        BooSocketTestSupport.waitUntil { gitHandled }
        XCTAssertTrue(gitHandled)
        XCTAssertFalse(dockerHandled)

        _ = try roundTrip(
            rawJSON: """
                {"cmd":"docker.list"}
                """)
        BooSocketTestSupport.waitUntil { dockerHandled }
        XCTAssertTrue(dockerHandled)
    }

    func testUnregisteredNamespaceReturnsError() throws {
        let resp = try roundTrip(
            rawJSON: """
                {"cmd":"nonexistent.action"}
                """)
        XCTAssertTrue((resp["error"] as? String)?.contains("unknown") ?? false)
    }

    func testMultipleCategories() throws {
        let pid = getpid()

        _ = try roundTrip(["cmd": "set_status", "pid": pid, "name": "jest", "category": "test"])
        BooSocketTestSupport.waitUntil { BooSocketServer.shared.processes[pid]?.category == "test" }
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "test")

        // Replace with different category
        _ = try roundTrip(["cmd": "set_status", "pid": pid, "name": "jest", "category": "build"])
        BooSocketTestSupport.waitUntil { BooSocketServer.shared.processes[pid]?.category == "build" }
        XCTAssertEqual(BooSocketServer.shared.processes[pid]?.category, "build")

        _ = try roundTrip(["cmd": "clear_status", "pid": pid])
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

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            cancellables = []
            bridge = TerminalBridge(paneID: paneID, workspaceID: workspaceID, workingDirectory: "/tmp")
            registry = PluginRegistry()
            debug = DebugPlugin()
            registry.register(debug)

            let bridge = bridge!
            let registry = registry!
            self.bridge.events.receive(on: DispatchQueue.main).sink { event in
                let ctx = TerminalContext(
                    terminalID: bridge.state.tabID,
                    cwd: bridge.state.workingDirectory,
                    remoteSession: nil, gitContext: nil,
                    processName: bridge.state.foregroundProcess,
                    paneCount: 1, tabCount: 1
                )
                switch event {
                case .processChanged(let name):
                    registry.notifyProcessChanged(name: name, context: ctx)
                    registry.runCycle(baseContext: ctx, reason: .processChanged)
                case .titleChanged:
                    registry.runCycle(baseContext: ctx, reason: .titleChanged)
                case .directoryChanged(let path):
                    registry.notifyCwdChanged(newPath: path, context: ctx)
                    registry.runCycle(baseContext: ctx, reason: .cwdChanged)
                default:
                    break
                }
            }.store(in: &cancellables)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            BooSocketServer.shared.processes.removeAll()
            cancellables = nil
            bridge = nil
            registry = nil
            debug = nil
        }
        try await super.tearDown()
    }

    private func processEvents() -> [DebugPlugin.LogEntry] {
        debug.entries.filter { $0.event == "processChanged" }
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: @escaping @MainActor () -> Bool
    ) {
        let expectation = expectation(description: "condition")
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if predicate() || Date() >= deadline {
                expectation.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
        }

        DispatchQueue.main.async(execute: poll)
        waitForExpectations(timeout: timeout + 0.2)
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
        waitUntil {
            let procEvents = self.processEvents()
            let starts = procEvents.filter { $0.detail.contains("name=claude") }
            let clears = procEvents.filter { $0.detail.contains("name=(empty)") }
            return !starts.isEmpty && !clears.isEmpty
        }
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
