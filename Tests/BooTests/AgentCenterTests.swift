import XCTest

@testable import Boo

@MainActor
final class AgentCenterTests: XCTestCase {
    func testAgentsManifestUsesCanonicalIDAndCustomSettingsPage() {
        let manifest = AgentsPlugin().manifest
        XCTAssertEqual(manifest.id, "agents")
        XCTAssertEqual(manifest.name, "Agents")
        XCTAssertTrue(manifest.settings?.contains { $0.type != .bool } ?? false)
    }

    func testLegacyClaudeCodeSettingsMigrateToAgents() {
        let defaults = UserDefaults.standard
        let settings = AppSettings.shared
        let originalPluginSettings = defaults.object(forKey: "pluginSettings")
        let originalOrder = settings.sidebarTabOrder
        let originalDisabled = settings.disabledPluginIDs

        defer {
            if let originalPluginSettings {
                defaults.set(originalPluginSettings, forKey: "pluginSettings")
            } else {
                defaults.removeObject(forKey: "pluginSettings")
            }
            settings.sidebarTabOrder = originalOrder
            settings.disabledPluginIDs = originalDisabled
        }

        defaults.set(
            [
                "claude-code": ["legacy": "yes"],
                "__sidebar": [
                    "sectionOrder": ["claude-code": ["agents.status", "agents.timeline"]],
                    "globalSelectedPluginTabID": "claude-code"
                ]
            ],
            forKey: "pluginSettings"
        )
        settings.sidebarTabOrder = ["git-panel", "claude-code"]
        settings.disabledPluginIDs = ["claude-code", "docker"]

        settings.migratePluginIdentity(from: "claude-code", to: "agents")

        XCTAssertEqual(settings.pluginSettingsDict(for: "agents")["legacy"] as? String, "yes")
        XCTAssertEqual(settings.sidebarTabOrder, ["git-panel", "agents"])
        XCTAssertEqual(settings.sidebarGlobalSelectedPluginTabID, "agents")
        XCTAssertEqual(settings.sidebarSectionOrder["agents"], ["agents.status", "agents.timeline"])
        XCTAssertTrue(settings.disabledPluginIDs.contains("agents"))
        XCTAssertFalse(settings.disabledPluginIDs.contains("claude-code"))
    }

    func testSocketMetadataBuildsAgentSession() {
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp/project",
            remoteSession: nil,
            gitContext: nil,
            processName: "claude",
            processPID: getpid(),
            processCategory: "ai",
            processMetadata: [
                "agent_kind": "claude-code",
                "session_id": "abc123",
                "transcript_path": "/tmp/transcript.jsonl",
                "model": "claude-opus",
                "permission_mode": "default",
                "state": "running"
            ],
            paneCount: 1,
            tabCount: 1
        )

        let session = AgentsPlugin.agentSession(from: ctx, existingStart: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(session?.kind, .claudeCode)
        XCTAssertEqual(session?.displayName, "Claude Code")
        XCTAssertEqual(session?.sessionID, "abc123")
        XCTAssertEqual(session?.transcriptPath, "/tmp/transcript.jsonl")
        XCTAssertEqual(session?.model, "claude-opus")
        XCTAssertEqual(session?.mode, "default")
        XCTAssertEqual(session?.state, .running)
    }

    func testMCPMetadataBuildAgentSessionID() {
        let startedAt = Date(timeIntervalSince1970: 1234)
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp/project",
            remoteSession: nil,
            gitContext: nil,
            processName: "opencode",
            processPID: getpid(),
            processCategory: "ai",
            processMetadata: [
                "agent_kind": "opencode",
                "session_id": "conv-42",
                "cwd": "/tmp/reported",
                "started_at": "\(startedAt.timeIntervalSince1970)",
                "state": "needs-input"
            ],
            paneCount: 1,
            tabCount: 1
        )

        let session = AgentsPlugin.agentSession(from: ctx, existingStart: nil)
        XCTAssertEqual(session?.kind, .openCode)
        XCTAssertEqual(session?.sessionID, "conv-42")
        XCTAssertEqual(session?.cwd, "/tmp/reported")
        XCTAssertEqual(session?.startedAt, startedAt)
        XCTAssertEqual(session?.state, .needsInput)
    }

    func testAgentConfigDetectsClaudeCodexAndOpenCode() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".codex"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".opencode/plugins"),
            withIntermediateDirectories: true)

        try "{}".write(
            toFile: (root as NSString).appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8)
        try """
        [mcp_servers.docs]
        command = "docs-server"
        """.write(
            toFile: (root as NSString).appendingPathComponent(".codex/config.toml"),
            atomically: true,
            encoding: .utf8)
        try """
        {"agent":{"plan":{"mode":"primary"}}}
        """.write(
            toFile: (root as NSString).appendingPathComponent("opencode.json"),
            atomically: true,
            encoding: .utf8)

        let config = AgentsPlugin.detectAgentConfig(cwd: root)

        XCTAssertTrue(config.configFiles.contains { $0.provider == .claudeCode })
        XCTAssertTrue(config.configFiles.contains { $0.provider == .codex })
        XCTAssertTrue(config.configFiles.contains { $0.provider == .openCode })
        XCTAssertTrue(config.skills.contains { $0.provider == .openCode && $0.name == "@plan" })
        XCTAssertTrue(config.setupRecommendations.contains { $0.kind == .claudeCode && $0.status == .detected })
    }

    private func makeTempProject() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-agent-center-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

}
