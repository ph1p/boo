import XCTest

@testable import Boo

final class CrashRecoveryTests: XCTestCase {

    private var dir: String!
    private var sessionFile: String!

    override func setUp() {
        super.setUp()
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("run-\(UUID().uuidString)")
        CrashRecovery._testDirectory = dir
        sessionFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-crash-\(UUID().uuidString).json")
        SessionStore.overrideFilePathForTesting(sessionFile)
    }

    override func tearDown() {
        CrashRecovery.resumeOnRestore = false
        try? FileManager.default.removeItem(atPath: dir)
        CrashRecovery.markLaunch(pid: 1, isAlive: { _ in false })  // reset previousRunCrashed
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: sessionFile)
        CrashRecovery._testDirectory = nil
        SessionStore.overrideFilePathForTesting(nil)
        super.tearDown()
    }

    private func pidFile(_ pid: pid_t) -> String {
        (dir as NSString).appendingPathComponent(String(pid))
    }

    // MARK: - Launch markers

    func testFirstLaunchIsNotACrash() {
        XCTAssertFalse(CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile(100)))
    }

    func testLeftoverFileOfDeadProcessIsACrash() {
        CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false })
        // Run 100 never quits cleanly; run 200 starts after it died.
        XCTAssertTrue(CrashRecovery.markLaunch(pid: 200, isAlive: { _ in false }))
        XCTAssertTrue(CrashRecovery.previousRunCrashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile(100)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile(200)))
    }

    func testFileOfRunningProcessIsNotACrash() {
        CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false })
        // A second Boo starts while 100 still runs.
        XCTAssertFalse(CrashRecovery.markLaunch(pid: 200, isAlive: { $0 == 100 }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile(100)))
    }

    func testCleanExitIsNotACrash() {
        CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false })
        CrashRecovery.markCleanExit(pid: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile(100)))
        XCTAssertFalse(CrashRecovery.markLaunch(pid: 200, isAlive: { _ in false }))
    }

    func testNonPIDFilesAreIgnored() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(".DS_Store"), contents: Data())
        XCTAssertFalse(CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false }))
    }

    // MARK: - Settings

    func testShouldResumeAgentsFollowsSettings() {
        let settings = AppSettings.shared
        let originalMode = settings.agentRecovery
        let originalAfterQuit = settings.resumeAgentsAfterQuit
        defer {
            settings.agentRecovery = originalMode
            settings.resumeAgentsAfterQuit = originalAfterQuit
        }

        settings.resumeAgentsAfterQuit = false
        settings.agentRecovery = .resume
        CrashRecovery.markLaunch(pid: 100, isAlive: { _ in false })
        XCTAssertFalse(CrashRecovery.shouldResumeAgents(settings: settings), "clean start")

        settings.resumeAgentsAfterQuit = true
        XCTAssertTrue(CrashRecovery.shouldResumeAgents(settings: settings), "after quit enabled")

        settings.resumeAgentsAfterQuit = false
        CrashRecovery.markLaunch(pid: 200, isAlive: { _ in false })  // 100 left a file: crash
        XCTAssertTrue(CrashRecovery.shouldResumeAgents(settings: settings), "after crash")

        settings.agentRecovery = .ask
        XCTAssertTrue(CrashRecovery.shouldResumeAgents(settings: settings))

        settings.agentRecovery = .off
        settings.resumeAgentsAfterQuit = true
        XCTAssertFalse(CrashRecovery.shouldResumeAgents(settings: settings), "off wins")
    }

    // MARK: - Resume commands

    func testResumeCommands() {
        XCTAssertEqual(AgentKind.claudeCode.resumeCommand(sessionID: "abc-1"), "claude --resume abc-1")
        XCTAssertEqual(AgentKind.codex.resumeCommand(sessionID: "abc-1"), "codex resume abc-1")
        XCTAssertEqual(AgentKind.openCode.resumeCommand(sessionID: "abc-1"), "opencode --session abc-1")
        XCTAssertNil(AgentKind.custom.resumeCommand(sessionID: "abc-1"))
    }

    func testResumeCommandEscapesSessionID() throws {
        let command = try XCTUnwrap(AgentKind.claudeCode.resumeCommand(sessionID: "x; rm -rf ~"))
        XCTAssertFalse(command.hasSuffix("x; rm -rf ~"))
    }

    // MARK: - Schedule / take

    func testScheduleAndTakeResume() {
        CrashRecovery.resumeOnRestore = true
        let tab = UUID()
        let agent = AgentResumePoint(kind: .claudeCode, sessionID: "s1", cwd: NSTemporaryDirectory())
        XCTAssertTrue(CrashRecovery.scheduleResume(agent, for: tab))
        let spec = CrashRecovery.takeResume(for: tab)
        XCTAssertEqual(spec?.command, "claude --resume s1")
        XCTAssertEqual(spec?.cwd, NSTemporaryDirectory())
        XCTAssertNil(CrashRecovery.takeResume(for: tab), "consumed once")
    }

    func testScheduleResumeDropsMissingDirectory() {
        CrashRecovery.resumeOnRestore = true
        let tab = UUID()
        let agent = AgentResumePoint(kind: .codex, sessionID: "s1", cwd: "/no/such/dir-\(UUID().uuidString)")
        XCTAssertTrue(CrashRecovery.scheduleResume(agent, for: tab))
        XCTAssertNil(CrashRecovery.takeResume(for: tab)?.cwd)
    }

    func testScheduleResumeNeedsResumeOnRestore() {
        CrashRecovery.resumeOnRestore = false
        let tab = UUID()
        XCTAssertFalse(
            CrashRecovery.scheduleResume(AgentResumePoint(kind: .claudeCode, sessionID: "s1", cwd: nil), for: tab))
        XCTAssertNil(CrashRecovery.takeResume(for: tab))
    }

    func testScheduleResumeSkipsCustomAgents() {
        CrashRecovery.resumeOnRestore = true
        let tab = UUID()
        XCTAssertFalse(
            CrashRecovery.scheduleResume(AgentResumePoint(kind: .custom, sessionID: "s1", cwd: nil), for: tab))
        XCTAssertNil(CrashRecovery.takeResume(for: tab))
    }

    // MARK: - Session file

    func testSessionTabRoundTripsAgent() throws {
        let agent = AgentResumePoint(kind: .openCode, sessionID: "s9", cwd: "/tmp")
        let data = try JSONEncoder().encode(SessionTab(agent: agent))
        XCTAssertEqual(try JSONDecoder().decode(SessionTab.self, from: data).agent, agent)
    }

    func testOldSessionTabWithoutAgentDecodes() throws {
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data("{}".utf8))
        XCTAssertNil(tab.agent)
    }

    @MainActor
    func testSnapshotKeepsAgentsAndRestoreSchedulesThem() throws {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = try XCTUnwrap(ws.pane(for: ws.activePaneID))
        pane.addTab(workingDirectory: "/tmp", title: "agent")
        state.addWorkspace(ws)
        let agentTab = try XCTUnwrap(pane.tabs.last).id
        let agent = AgentResumePoint(kind: .claudeCode, sessionID: "s1", cwd: "/tmp")

        let window = SessionStore.buildWindow(appState: state, agents: [agentTab: agent])
        var snapshot = SessionSnapshot(activeWorkspaceIndex: 0, workspaces: window.workspaces)
        snapshot.windows = [window]
        XCTAssertEqual(WindowManager.agentCount(in: snapshot), 1)

        CrashRecovery.resumeOnRestore = true
        let restored = SessionStore.workspaces(from: snapshot)
        let restoredPane = try XCTUnwrap(restored.first?.pane(for: restored[0].activePaneID))
        let specs = restoredPane.tabs.compactMap { CrashRecovery.takeResume(for: $0.id) }
        XCTAssertEqual(specs.map(\.command), ["claude --resume s1"])
    }
}
