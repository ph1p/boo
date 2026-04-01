import XCTest

@testable import Boo

/// Tests for the AIAgentPlugin lifecycle — specifically the teardown behavior
/// when processes change and activity states transition.
@MainActor
final class AIAgentPluginLifecycleTests: XCTestCase {

    private var plugin: AIAgentPlugin!
    private var cycleRerunCount: Int = 0

    override func setUp() {
        super.setUp()
        cycleRerunCount = 0
        plugin = AIAgentPlugin()
        plugin.onRequestCycleRerun = { [weak self] in
            self?.cycleRerunCount += 1
        }
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
            gitContext: TerminalContext.GitContext(
                branch: "main", repoRoot: "/tmp/project",
                isDirty: false, changedFileCount: 0, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil
            ),
            processName: processName,
            paneCount: 1,
            tabCount: 1
        )
    }

    // MARK: - Basic Agent Detection

    func testAgentDetectedOnProcessChange() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)

        XCTAssertEqual(plugin.agentName, "claude")
        XCTAssertEqual(plugin.agentDisplayName, "Claude")
        XCTAssertNotNil(plugin.agentStartTime)
    }

    func testNonAIProcessIgnoredWhenNoAgent() {
        let ctx = makeContext(processName: "vim")
        plugin.processChanged(name: "vim", context: ctx)

        XCTAssertNil(plugin.agentName)
    }

    // MARK: - Visibility Override

    func testVisibleWhileAgentNameSet() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)

        // Visible even if context says different process
        let shellCtx = makeContext(processName: "zsh")
        XCTAssertTrue(plugin.isVisible(for: shellCtx))
    }

    func testNotVisibleAfterTeardown() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)

        // Simulate: process changes to shell, then wait for teardown
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Still visible during grace period
        XCTAssertTrue(plugin.isVisible(for: shellCtx))

        // Wait for grace period to expire
        let exp = expectation(description: "teardown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        // Now teardown has happened
        XCTAssertNil(plugin.agentName)
        XCTAssertFalse(plugin.isVisible(for: shellCtx))
    }

    // MARK: - Core Bug Fix: Process switches away never tears down immediately

    func testProcessSwitchAwayNeverTearsDownImmediately() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)
        XCTAssertEqual(plugin.agentName, "claude")

        // Process changes to shell with activity idle — should NOT tear down immediately
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Agent should still be set (deferred teardown pending)
        XCTAssertEqual(plugin.agentName, "claude")
        XCTAssertEqual(cycleRerunCount, 0, "Should not have called cycle rerun yet")
    }

    func testProcessSwitchAwayWithRunningAlsoDefers() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)

        // Process changes to git with running activity
        let gitCtx = makeContext(processName: "git")
        plugin.processChanged(name: "git", context: gitCtx)

        XCTAssertEqual(plugin.agentName, "claude")
        XCTAssertEqual(cycleRerunCount, 0)
    }

    // MARK: - Process returns to AI cancels teardown

    func testProcessReturnsToAICancelsTeardown() {
        let ctx = makeContext(processName: "claude")
        plugin.processChanged(name: "claude", context: ctx)

        // Process briefly switches away
        let shellCtx = makeContext(processName: "zsh")
        plugin.processChanged(name: "zsh", context: shellCtx)

        // Process comes back to AI
        plugin.processChanged(name: "claude", context: ctx)

        // Wait past the grace period
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // Should NOT have torn down — the process came back
        XCTAssertEqual(plugin.agentName, "claude")
    }

    // MARK: - Simulate real Claude Code session

    func testFullClaudeCodeSession() {
        // 1. Claude starts
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")

        // 2. Claude spawns git subprocess — title changes briefly
        plugin.processChanged(name: "git", context: makeContext(processName: "git"))
        XCTAssertEqual(plugin.agentName, "claude", "Should not tear down during git")

        // 3. Git finishes, Claude comes back
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")

        // No teardown at any point
        XCTAssertEqual(cycleRerunCount, 0)
    }

    func testFullClaudeCodeSessionWithSocketUnregister() {
        // 1. Claude starts
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")

        // 2. Claude Code finishes a prompt — spawns git
        plugin.processChanged(name: "git", context: makeContext(processName: "git"))
        XCTAssertEqual(plugin.agentName, "claude")

        // 3. Git finishes, title falls back to shell
        plugin.processChanged(name: "", context: makeContext(processName: ""))
        XCTAssertEqual(plugin.agentName, "claude", "Grace period should protect")

        // 4. Claude re-registers via socket
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")
        XCTAssertEqual(cycleRerunCount, 0, "No teardown should have occurred")
    }

    func testClaudeExitsForReal() {
        // 1. Claude starts
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))

        // 2. Claude exits — process changes to shell
        plugin.processChanged(name: "", context: makeContext(processName: ""))
        XCTAssertEqual(plugin.agentName, "claude", "Grace period active")

        // 3. Wait for grace period to expire
        let exp = expectation(description: "teardown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // Teardown should happen now
        XCTAssertNil(plugin.agentName)
    }

    func testGracePeriodExpiresWhenNothingComesBack() {
        // 1. Claude starts
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))

        // 2. Claude exits
        plugin.processChanged(name: "zsh", context: makeContext(processName: "zsh"))
        XCTAssertEqual(plugin.agentName, "claude")

        // 3. Wait for grace period
        let exp = expectation(description: "grace period")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // 4. Teardown should have happened
        XCTAssertNil(plugin.agentName)
    }

    // MARK: - pluginDidDeactivate

    func testDeactivateCleansUp() {
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")

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
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))
        XCTAssertEqual(plugin.agentName, "claude")
        XCTAssertEqual(cycleRerunCount, 0)
    }

    // MARK: - Focus change

    func testFocusChangeCancelsTeardown() {
        // Claude is running
        plugin.processChanged(name: "claude", context: makeContext(processName: "claude"))

        // Process briefly switches away
        plugin.processChanged(name: "zsh", context: makeContext(processName: "zsh"))

        // Focus changes to a pane where Claude is running
        plugin.terminalFocusChanged(
            terminalID: UUID(),
            context: makeContext(processName: "claude")
        )

        // Wait past grace period
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // Should not have torn down
        XCTAssertEqual(plugin.agentName, "claude")
    }
}
