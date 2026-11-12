import XCTest

@testable import Boo

final class AgentAdapterTests: XCTestCase {

    func testEveryTaskKindHasAnAdapter() {
        for kind in AgentKind.taskKinds {
            let adapter = try? XCTUnwrap(kind.adapter, "\(kind) has no adapter")
            XCTAssertEqual(adapter?.kind, kind)
            XCTAssertEqual(AgentKind(ipcName: kind.ipcName), kind)
        }
        XCTAssertNil(AgentKind.custom.adapter)
        XCTAssertEqual(Set(AgentKind.detectionOrder), Set(AgentKind.taskKinds))
    }

    func testIPCNames() {
        XCTAssertEqual(AgentKind.claudeCode.ipcName, "claude")
        XCTAssertEqual(AgentKind.copilot.ipcName, "copilot")
        XCTAssertEqual(AgentKind.pi.ipcName, "pi")
        XCTAssertEqual(AgentKind.hermes.ipcName, "hermes")
        XCTAssertEqual(AgentKind(ipcName: "hermes"), .hermes)
        XCTAssertNil(AgentKind(ipcName: "custom"))
        XCTAssertTrue(AgentKind.ipcNameList.contains("copilot"))
        XCTAssertTrue(AgentKind.binaryList.hasSuffix(" or hermes"))
    }

    func testStartCommands() {
        XCTAssertEqual(CopilotAdapter().command(.start(model: nil)), "copilot")
        XCTAssertEqual(
            CopilotAdapter().command(.start(model: "gpt-5"), prompt: "'fix it'"), "copilot --model 'gpt-5' -i 'fix it'")
        XCTAssertEqual(PiAdapter().command(.start(model: nil), prompt: "'fix it'"), "pi 'fix it'")
        XCTAssertEqual(HermesAdapter().command(.start(model: nil)), "hermes chat")
        XCTAssertEqual(
            HermesAdapter().command(.start(model: "m"), prompt: "\"$_BOO_PROMPT\""),
            "_BOO_FIRST_PROMPT=\"$_BOO_PROMPT\" hermes chat --model 'm'")
        XCTAssertEqual(ClaudeCodeAdapter().command(.start(model: " "), prompt: ""), "claude")
    }

    func testContinueAndResumeCommands() {
        XCTAssertEqual(CopilotAdapter().command(.continueLast), "copilot --continue")
        XCTAssertEqual(CopilotAdapter().command(.resume(sessionID: "s1")), "copilot --resume=s1")
        XCTAssertEqual(PiAdapter().command(.resume(sessionID: "s1")), "pi --session s1")
        XCTAssertEqual(HermesAdapter().command(.continueLast), "hermes chat --continue")
        XCTAssertEqual(
            AgentKind.hermes.resumeCommand(sessionID: "s1", prompt: "go on"),
            "_BOO_FIRST_PROMPT='go on' hermes chat --resume s1")
        XCTAssertEqual(
            AgentKind.copilot.resumeCommand(sessionID: "s1", prompt: "go on"), "copilot --resume=s1 -i 'go on'")
    }

    func testInferMatchesAliasesAndProcessNames() {
        XCTAssertEqual(AgentKind.infer(processName: "zsh", metadata: ["agent_kind": "GitHub-Copilot"]), .copilot)
        XCTAssertEqual(AgentKind.infer(processName: "zsh", metadata: ["agent_kind": "claude-code"]), .claudeCode)
        XCTAssertEqual(AgentKind.infer(processName: "hermes", metadata: [:]), .hermes)
        XCTAssertEqual(AgentKind.infer(processName: "pi", metadata: [:]), .pi)
        XCTAssertNil(AgentKind.infer(processName: "vim", metadata: [:]))
    }

    func testTitleMatching() {
        XCTAssertEqual(ProcessIcon.matchTitle("GitHub Copilot"), "copilot")
        XCTAssertEqual(ProcessIcon.matchTitle("⠂ copilot: thinking"), "copilot")
        XCTAssertEqual(ProcessIcon.matchTitle("hermes"), "hermes")
        // Hermes running a Claude model still counts as Hermes.
        XCTAssertEqual(ProcessIcon.matchTitle("hermes · claude-sonnet"), "hermes")
        XCTAssertNil(ProcessIcon.matchTitle("my-copilot-tool"))
    }

    func testProcessIconFallsBackToAdapters() {
        XCTAssertEqual(ProcessIcon.icon(for: "hermes"), "sparkles")
        XCTAssertEqual(ProcessIcon.displayName(for: "pi"), "pi")
        XCTAssertEqual(ProcessIcon.category(for: "Hermes"), "ai")
    }

    func testCopilotHooksJSON() throws {
        let data = try XCTUnwrap(CopilotAdapter.hooksJSON(hook: "/Users/me/.boo/shell-integration/boo-claude-hook"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(CopilotAdapter.hookEvents))
        let stop = try XCTUnwrap(hooks["agentStop"]?.first)
        XCTAssertEqual(stop["type"] as? String, "command")
        XCTAssertEqual(stop["bash"] as? String, "/Users/me/.boo/shell-integration/boo-claude-hook copilot agentStop")
    }

    func testConfigScanUsesAdapterFiles() throws {
        let root = NSTemporaryDirectory() + "boo-adapter-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/.github", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.pi", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/.github/copilot-instructions.md", contents: Data())
        fm.createFile(atPath: root + "/.pi/settings.json", contents: Data())
        fm.createFile(atPath: root + "/HERMES.md", contents: Data())

        let files = AgentsPlugin.detectAgentConfig(cwd: root, projectRoot: root).configFiles
            .filter { $0.scope == "project" }
        XCTAssertEqual(files.first { $0.path.hasSuffix("copilot-instructions.md") }?.provider, .copilot)
        XCTAssertEqual(files.first { $0.path.hasSuffix(".pi/settings.json") }?.provider, .pi)
        XCTAssertEqual(files.first { $0.path.hasSuffix("HERMES.md") }?.provider, .hermes)
    }
}
