import Combine
import XCTest

@testable import Boo

/// End-to-end tests that drive the full pipeline (TerminalBridge → PluginRegistry →
/// DebugPlugin) and assert against the DebugPlugin's event log.
/// The DebugPlugin acts as an observable recorder: every lifecycle callback it
/// receives is appended to `entries`, so we can verify the exact sequence of events
/// that a real terminal session would produce.
@MainActor
final class DebugPluginE2ETests: XCTestCase {

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
            self.bridge.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    let ctx = TerminalContext(
                        terminalID: bridge.state.tabID,
                        cwd: bridge.state.workingDirectory,
                        remoteSession: bridge.state.remoteSession,
                        gitContext: nil,
                        processName: bridge.state.foregroundProcess,
                        paneCount: 1,
                        tabCount: 1
                    )
                    switch event {
                    case .directoryChanged(let path):
                        registry.notifyCwdChanged(newPath: path, context: ctx)
                        registry.runCycle(baseContext: ctx, reason: .cwdChanged)
                    case .processChanged(let name):
                        registry.notifyProcessChanged(name: name, context: ctx)
                        registry.runCycle(baseContext: ctx, reason: .processChanged)
                    case .remoteSessionChanged(let session):
                        registry.notifyRemoteSessionChanged(session: session, context: ctx)
                        registry.runCycle(baseContext: ctx, reason: .remoteSessionChanged)
                    case .titleChanged:
                        registry.runCycle(baseContext: ctx, reason: .titleChanged)
                    case .focusChanged:
                        break
                    default:
                        break
                    }
                }.store(in: &cancellables)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            cancellables = nil
            bridge = nil
            registry = nil
            debug = nil
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

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

    private func events(named name: String) -> [DebugPlugin.LogEntry] {
        debug.entries.filter { $0.event == name }
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

    private func waitForEvents(named name: String, count: Int) -> [DebugPlugin.LogEntry] {
        waitUntil { self.events(named: name).count >= count }
        return events(named: name)
    }

    // MARK: - Directory Change E2E

    func testCwdChangePropagates() {
        bridge.handleDirectoryChange(path: "/Users/test/project", paneID: paneID)

        let cwdEvents = waitForEvents(named: "cwdChanged", count: 1)
        XCTAssertEqual(cwdEvents.count, 1)
        XCTAssertTrue(cwdEvents[0].detail.contains("/Users/test/project"))
    }

    func testDuplicateCwdIgnored() {
        bridge.handleDirectoryChange(path: "/tmp", paneID: paneID)  // same as initial
        XCTAssertTrue(events(named: "cwdChanged").isEmpty)
    }

    func testMultipleCwdChanges() {
        bridge.handleDirectoryChange(path: "/a", paneID: paneID)
        bridge.handleDirectoryChange(path: "/b", paneID: paneID)
        bridge.handleDirectoryChange(path: "/c", paneID: paneID)

        let cwdEvents = waitForEvents(named: "cwdChanged", count: 3)
        XCTAssertEqual(cwdEvents.count, 3)
        XCTAssertTrue(cwdEvents[0].detail.contains("/a"))
        XCTAssertTrue(cwdEvents[1].detail.contains("/b"))
        XCTAssertTrue(cwdEvents[2].detail.contains("/c"))
    }

    // MARK: - Process Change E2E

    func testProcessChangePropagates() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)

        let procEvents = waitForEvents(named: "processChanged", count: 1)
        XCTAssertEqual(procEvents.count, 1)
        XCTAssertTrue(procEvents[0].detail.contains("name=vim"))
        XCTAssertTrue(procEvents[0].detail.contains("category=editor"))
    }

    func testProcessCategoryDetected() {
        bridge.handleTitleChange(title: "node server.js", paneID: paneID)

        let procEvents = waitForEvents(named: "processChanged", count: 1)
        XCTAssertEqual(procEvents.count, 1)
        XCTAssertTrue(procEvents[0].detail.contains("name=node"))
        XCTAssertTrue(procEvents[0].detail.contains("category=runtime"))
    }

    func testTitleClearsProcess() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        bridge.handleTitleChange(title: "~/project", paneID: paneID)

        let procEvents = waitForEvents(named: "processChanged", count: 2)
        XCTAssertEqual(procEvents.count, 2)
        XCTAssertTrue(procEvents[0].detail.contains("name=vim"))
        XCTAssertTrue(procEvents[1].detail.contains("name=(empty)"))
    }

    func testShellProcessClears() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        bridge.handleTitleChange(title: "zsh", paneID: paneID)

        let procEvents = waitForEvents(named: "processChanged", count: 2)
        XCTAssertEqual(procEvents.count, 2)
        XCTAssertTrue(procEvents[0].detail.contains("name=vim"))
        XCTAssertTrue(procEvents[1].detail.contains("name=(empty)"))
    }

    func testSameTitleNoRepeatedEvent() {
        bridge.handleTitleChange(title: "vim", paneID: paneID)
        bridge.handleTitleChange(title: "vim", paneID: paneID)

        let procEvents = waitForEvents(named: "processChanged", count: 1)
        XCTAssertEqual(procEvents.count, 1, "Duplicate title should not emit duplicate processChanged")
    }

    // MARK: - Remote Session E2E

    func testSSHSessionDetected() {
        bridge.handleTitleChange(title: "ssh user@server.example.com", paneID: paneID)

        let remoteEvents = waitForEvents(named: "remoteSessionChanged", count: 1)
        XCTAssertEqual(remoteEvents.count, 1)
        XCTAssertTrue(remoteEvents[0].detail.contains("ssh"))
    }

    func testSSHSessionEndsOnShell() {
        bridge.handleTitleChange(title: "ssh user@server.example.com", paneID: paneID)
        bridge.handleTitleChange(title: "zsh", paneID: paneID)

        let remoteEvents = waitForEvents(named: "remoteSessionChanged", count: 2)
        XCTAssertEqual(remoteEvents.count, 2, "Should get session start + session end")
        // Last event should be session cleared
        XCTAssertTrue(remoteEvents[1].detail.contains("session=nil"))
    }

    func testDockerSessionDetected() {
        bridge.handleTitleChange(title: "docker exec -it myapp bash", paneID: paneID)

        let remoteEvents = waitForEvents(named: "remoteSessionChanged", count: 1)
        XCTAssertEqual(remoteEvents.count, 1)
        XCTAssertTrue(remoteEvents[0].detail.contains("docker") || remoteEvents[0].detail.contains("container"))
    }

    // MARK: - Terminal Lifecycle E2E

    func testTerminalCreatedLogged() {
        let termID = UUID()
        registry.notifyTerminalCreated(terminalID: termID)

        let createEvents = waitForEvents(named: "terminalCreated", count: 1)
        XCTAssertEqual(createEvents.count, 1)
        XCTAssertTrue(createEvents[0].detail.contains(termID.uuidString.prefix(8)))
    }

    func testTerminalClosedLogged() {
        let termID = UUID()
        registry.notifyTerminalCreated(terminalID: termID)
        registry.notifyTerminalClosed(terminalID: termID)

        XCTAssertEqual(events(named: "terminalCreated").count, 1)
        XCTAssertEqual(events(named: "terminalClosed").count, 1)
    }

    // MARK: - Focus Change E2E

    func testFocusChangeLogged() {
        let termID = UUID()
        let ctx = currentContext()
        registry.notifyFocusChanged(terminalID: termID, context: ctx)

        let focusEvents = waitForEvents(named: "focusChanged", count: 1)
        XCTAssertEqual(focusEvents.count, 1)
        XCTAssertTrue(focusEvents[0].detail.contains(termID.uuidString.prefix(8)))
    }

    // MARK: - Remote Directory Listing E2E

    func testRemoteDirectoryListingLogged() {
        let entries = [
            RemoteExplorer.RemoteEntry(name: "src", isDirectory: true),
            RemoteExplorer.RemoteEntry(name: "README.md", isDirectory: false),
            RemoteExplorer.RemoteEntry(name: "lib", isDirectory: true)
        ]
        registry.notifyRemoteDirectoryListed(path: "/home/user/project", entries: entries)

        let listEvents = waitForEvents(named: "remoteDirectoryListed", count: 1)
        XCTAssertEqual(listEvents.count, 1)
        XCTAssertTrue(listEvents[0].detail.contains("dirs=2"))
        XCTAssertTrue(listEvents[0].detail.contains("files=1"))
    }

    // MARK: - Enrich/React Cycle E2E

    func testCycleLogsEnrichAndReact() {
        let ctx = currentContext()
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        waitUntil {
            !self.events(named: "enrich").isEmpty && !self.events(named: "react").isEmpty
        }
        XCTAssertFalse(events(named: "enrich").isEmpty, "enrich should be logged")
        XCTAssertFalse(events(named: "react").isEmpty, "react should be logged")
    }

    func testEnrichRunsBeforeReact() {
        let ctx = currentContext()
        registry.runCycle(baseContext: ctx, reason: .focusChanged)

        waitUntil {
            self.debug.entries.contains { $0.event == "enrich" }
                && self.debug.entries.contains { $0.event == "react" }
        }
        let enrichIdx = debug.entries.firstIndex { $0.event == "enrich" }
        let reactIdx = debug.entries.firstIndex { $0.event == "react" }
        XCTAssertNotNil(enrichIdx)
        XCTAssertNotNil(reactIdx)
        XCTAssertTrue(enrichIdx! < reactIdx!, "enrich must run before react")
    }

    // MARK: - Combined Scenario E2E

    /// Simulates a real user session: open terminal → cd to project → start vim →
    /// quit vim → ssh into server → return to local shell.
    func testFullSessionScenario() {
        // 1. Initial state — cd to project
        bridge.handleDirectoryChange(path: "/Users/dev/myproject", paneID: paneID)

        // 2. User opens vim
        bridge.handleTitleChange(title: "vim", paneID: paneID)

        // 3. User quits vim — shell resumes
        bridge.handleTitleChange(title: "zsh", paneID: paneID)

        // 4. User SSHs into server
        bridge.handleTitleChange(title: "ssh deploy@prod-01.example.com", paneID: paneID)

        // 5. User exits SSH — shell resumes
        bridge.handleTitleChange(title: "zsh", paneID: paneID)

        waitUntil {
            self.events(named: "cwdChanged").count >= 1
                && self.events(named: "processChanged").count >= 2
                && self.events(named: "remoteSessionChanged").count >= 1
                && self.events(named: "enrich").count >= 4
                && self.events(named: "react").count >= 4
        }

        // Verify event sequence
        let allEvents = debug.entries.map(\.event)

        // Should have cwd change
        XCTAssertTrue(allEvents.contains("cwdChanged"))

        // Should have process changes from title detection
        let procEvents = waitForEvents(named: "processChanged", count: 2)
        XCTAssertGreaterThanOrEqual(procEvents.count, 2, "At least vim start + vim end")

        // Should have remote session start + end
        let remoteEvents = waitForEvents(named: "remoteSessionChanged", count: 1)
        XCTAssertGreaterThanOrEqual(remoteEvents.count, 1, "SSH should trigger remote session")

        // Should have multiple enrich/react cycles
        waitUntil {
            self.events(named: "enrich").count >= 4
                && self.events(named: "react").count >= 4
        }
        let enrichCount = events(named: "enrich").count
        let reactCount = events(named: "react").count
        XCTAssertEqual(enrichCount, reactCount, "Every enrich has a matching react")
        XCTAssertGreaterThanOrEqual(enrichCount, 4, "Multiple cycles from cwd + title changes")
    }

    // MARK: - Log Management

    func testMaxEntriesRespected() {
        debug.maxEntries = 5

        // Generate many events
        for i in 0..<20 {
            bridge.handleDirectoryChange(path: "/path/\(i)", paneID: paneID)
        }

        XCTAssertLessThanOrEqual(debug.entries.count, 5, "Log should be capped")
    }

    // MARK: - Wrong Pane Isolation

    func testEventsFromWrongPaneIgnored() {
        let otherPane = UUID()
        bridge.handleTitleChange(title: "vim", paneID: otherPane)
        bridge.handleDirectoryChange(path: "/other", paneID: otherPane)

        // No lifecycle events should reach the debug plugin
        XCTAssertTrue(events(named: "cwdChanged").isEmpty)
        XCTAssertTrue(events(named: "processChanged").isEmpty)
    }
}
