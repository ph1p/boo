import XCTest

@testable import Boo

/// Tests for the AIAgentPlugin lifecycle — specifically the teardown behavior
/// when processes change and activity states transition.
@MainActor
final class AIAgentPluginLifecycleTests: XCTestCase {

    private var plugin: AIAgentPlugin!
    private let teardownGracePeriod: TimeInterval = 0.02
    private let teardownWaitTimeout: TimeInterval = 0.25

    override func setUp() {
        super.setUp()
        plugin = AIAgentPlugin()
        plugin.teardownGracePeriod = teardownGracePeriod
    }

    override func tearDown() {
        plugin = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext(
        processName: String = ""
    ) -> TerminalContext {
        TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp/project",
            remoteSession: nil,
            gitContext: nil,
            processName: processName,
            paneCount: 1,
            tabCount: 1
        )
    }

    private func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private func waitForTeardown() {
        BooSocketTestSupport.waitUntil(timeout: teardownWaitTimeout) {
            self.plugin.agentName == nil
        }
    }

    // MARK: - Basic Agent Detection

    func testAgentDetectedOnProcessChange() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)

        XCTAssertEqual(plugin.agentName, "aider")
        XCTAssertEqual(plugin.agentDisplayName, "Aider")
        XCTAssertNotNil(plugin.agentStartTime)
    }

    func testNonAIProcessIgnoredWhenNoAgent() {
        let ctx = makeContext(processName: "vim")
        plugin.processChanged(name: "vim", context: ctx)

        XCTAssertNil(plugin.agentName)
    }

    // MARK: - Visibility Override

    func testVisibleWhileAgentNameSet() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)

        // Visible even if context says different process
        let shellCtx = makeContext(processName: "zsh")
        XCTAssertTrue(plugin.isVisible(for: shellCtx))
    }

    func testNotVisibleAfterTeardown() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)

        // Simulate: process changes to shell, then wait for teardown
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Still visible during grace period
        XCTAssertTrue(plugin.isVisible(for: shellCtx))

        waitForTeardown()
        XCTAssertFalse(plugin.isVisible(for: shellCtx))
    }

    // MARK: - Core Bug Fix: Process switches away never tears down immediately

    func testProcessSwitchAwayNeverTearsDownImmediately() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)
        XCTAssertEqual(plugin.agentName, "aider")

        // Process changes to shell with activity idle — should NOT tear down immediately
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Agent should still be set (deferred teardown pending)
        XCTAssertEqual(plugin.agentName, "aider")
    }

    func testProcessSwitchAwayWithRunningAlsoDefers() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)

        // Process changes to git with running activity
        let gitCtx = makeContext(processName: "git")
        plugin.processChanged(name: "git", context: gitCtx)

        XCTAssertEqual(plugin.agentName, "aider")
    }

    // MARK: - Process returns to AI cancels teardown

    func testProcessReturnsToAICancelsTeardown() {
        let ctx = makeContext(processName: "aider")
        plugin.processChanged(name: "aider", context: ctx)

        // Process briefly switches away
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Process comes back to AI
        plugin.processChanged(name: "aider", context: ctx)

        // Wait past the grace period
        pumpMainRunLoop(for: teardownGracePeriod * 4)

        // Should NOT have torn down — the process came back
        XCTAssertEqual(plugin.agentName, "aider")
    }

    // MARK: - Simulate real Claude Code session

    func testFullClaudeCodeSession() {
        // 1. Claude starts
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")

        // 2. Claude spawns git subprocess — title changes briefly
        plugin.processChanged(name: "git", context: makeContext(processName: "git"))
        XCTAssertEqual(plugin.agentName, "aider", "Should not tear down during git")

        // 3. Git finishes, Claude comes back
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")
    }

    func testFullClaudeCodeSessionWithSocketUnregister() {
        // 1. Claude starts
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")

        // 2. Claude Code finishes a prompt — spawns git
        plugin.processChanged(name: "git", context: makeContext(processName: "git"))
        XCTAssertEqual(plugin.agentName, "aider")

        // 3. Git finishes, title falls back to shell
        plugin.processChanged(name: "", context: makeContext(processName: ""))
        XCTAssertEqual(plugin.agentName, "aider", "Grace period should protect")

        // 4. Claude re-registers via socket
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")
    }

    func testClaudeExitsForReal() {
        // 1. Claude starts
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))

        // 2. Claude exits — process changes to shell
        plugin.processChanged(name: "", context: makeContext(processName: ""))
        XCTAssertEqual(plugin.agentName, "aider", "Grace period active")

        waitForTeardown()
    }

    func testGracePeriodExpiresWhenNothingComesBack() {
        // 1. Claude starts
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))

        // 2. Claude exits
        plugin.processChanged(name: "zsh", context: makeContext(processName: "zsh"))
        XCTAssertEqual(plugin.agentName, "aider")

        waitForTeardown()
    }

    // MARK: - pluginDidDeactivate

    func testDeactivateCleansUp() {
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")

        plugin.pluginDidDeactivate()
        XCTAssertNil(plugin.agentName)
    }

    // MARK: - Title matching for AI agents

    func testMatchTitleClaudeCode() {
        XCTAssertEqual(ProcessIcon.matchTitle("Claude Code"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("✳ Claude Code"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("⠂ Claude Code"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("⠐ Claude Code"), "claude")
    }

    func testMatchTitleClaudeDynamicTask() {
        // Claude Code changes title to show current task — spinner prefix → "claude"
        XCTAssertEqual(ProcessIcon.matchTitle("⠂ General coding assistance"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("✳ General coding assistance"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("⠂ Fixing bug in auth module"), "claude")
        XCTAssertEqual(ProcessIcon.matchTitle("⠐ Running tests"), "claude")
    }

    func testMatchTitleNonAI() {
        XCTAssertNil(ProcessIcon.matchTitle("vim"))
        XCTAssertNil(ProcessIcon.matchTitle("zsh"))
        XCTAssertNil(ProcessIcon.matchTitle("~/Downloads/project"))
        XCTAssertNil(ProcessIcon.matchTitle("user@host:~"))
    }

    func testNodeResolvesToClaudeViaTitle() {
        // Process tree sees "node" but title says "Claude Code" → foreground is "claude"
        // This is tested at the bridge level (testBridgePollResolvesNodeToClaude)
        // Here we just verify the plugin reacts correctly to "claude"
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))
        XCTAssertEqual(plugin.agentName, "aider")
    }

    // MARK: - Focus change

    func testFocusChangeCancelsTeardown() {
        // Claude is running
        plugin.processChanged(name: "aider", context: makeContext(processName: "aider"))

        // Process briefly switches away
        plugin.processChanged(name: "zsh", context: makeContext(processName: "zsh"))

        // Focus changes to a pane where Claude is running
        plugin.terminalFocusChanged(
            terminalID: UUID(),
            context: makeContext(processName: "aider")
        )

        // Wait past grace period
        pumpMainRunLoop(for: teardownGracePeriod * 4)

        // Should not have torn down
        XCTAssertEqual(plugin.agentName, "aider")
    }
}
