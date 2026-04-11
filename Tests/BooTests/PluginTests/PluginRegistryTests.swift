import XCTest

@testable import Boo

@MainActor
final class PluginRegistryTests: XCTestCase {

    private func makeContext(
        remote: RemoteSessionType? = nil,
        gitBranch: String? = nil
    ) -> TerminalContext {
        let git: TerminalContext.GitContext?
        if let branch = gitBranch {
            git = TerminalContext.GitContext(
                branch: branch, repoRoot: "/repo", isDirty: true, changedFileCount: 3, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil)
        } else {
            git = nil
        }
        return TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: remote,
            gitContext: git,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
    }

    func testRegisterBuiltins() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        XCTAssertEqual(registry.plugins.count, 9)
        XCTAssertNotNil(registry.plugin(for: "file-tree-local"))
        XCTAssertNotNil(registry.plugin(for: "file-tree-remote"))
        XCTAssertNotNil(registry.plugin(for: "git-panel"))
        XCTAssertNotNil(registry.plugin(for: "ai-agent"))
        XCTAssertNotNil(registry.plugin(for: "docker"))
        XCTAssertNotNil(registry.plugin(for: "bookmarks"))
        XCTAssertNotNil(registry.plugin(for: "system-info"))
        XCTAssertNotNil(registry.plugin(for: "debug"))
    }

    func testUnregister() {
        let registry = PluginRegistry()
        registry.registerBuiltins()
        registry.unregister(pluginID: "docker")
        XCTAssertEqual(registry.plugins.count, 8)
        XCTAssertNil(registry.plugin(for: "docker"))
    }

    func testCycleReturnsVisiblePlugins() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        // Local context with git
        let localGit = makeContext(gitBranch: "main")
        let result = registry.runCycle(baseContext: localGit, reason: .focusChanged)

        // file-tree-local, bookmarks, docker always visible locally; git visible when git.active
        XCTAssertTrue(result.visiblePluginIDs.contains("file-tree-local"))
        XCTAssertTrue(result.visiblePluginIDs.contains("bookmarks"))
        XCTAssertTrue(result.visiblePluginIDs.contains("git-panel"))
        XCTAssertTrue(result.visiblePluginIDs.contains("docker"))
    }

    func testDockerNotVisibleInRemoteContext() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let sshCtx = makeContext(remote: .ssh(host: "server"))
        let result = registry.runCycle(baseContext: sshCtx, reason: .focusChanged)

        // Docker plugin uses !remote — hidden during SSH
        XCTAssertFalse(result.visiblePluginIDs.contains("docker"))
    }

    func testGitNotVisibleWithoutRepo() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let noGit = makeContext()
        let result = registry.runCycle(baseContext: noGit, reason: .focusChanged)

        XCTAssertFalse(result.visiblePluginIDs.contains("git-panel"))
    }

    func testStatusBarContentCollected() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let localGit = makeContext(gitBranch: "main")
        let result = registry.runCycle(baseContext: localGit, reason: .focusChanged)

        // Verify at least some plugins provide status bar content
        XCTAssertGreaterThan(result.statusBarContents.count, 0, "Should have status bar content from plugins")

        // If file-tree-local should always provide content:
        let fileTreeContent = result.statusBarContents.first { $0.pluginID == "file-tree-local" }
        XCTAssertNotNil(fileTreeContent, "file-tree-local should provide status bar content")
    }

    func testGitStatusBarContent() {
        let registry = PluginRegistry()
        registry.registerBuiltins()

        let localGit = makeContext(gitBranch: "feature/auth")
        let result = registry.runCycle(baseContext: localGit, reason: .focusChanged)

        let gitContent = result.statusBarContents.first { $0.pluginID == "git-panel" }
        XCTAssertNotNil(gitContent)
        XCTAssertTrue(gitContent?.content.text.contains("feature/auth") ?? false)
        // Note: cached file count may be 0 in tests (no actual git status run)
        // The branch name is the important assertion here
    }

    func testBookmarkNamespacing() {
        let local = makeContext()
        let ssh = makeContext(remote: .ssh(host: "prod-01"))
        let docker = makeContext(remote: .container(target: "app", tool: .docker))

        XCTAssertEqual(BookmarksPluginNew.namespace(for: local), "local")
        XCTAssertEqual(BookmarksPluginNew.namespace(for: ssh), "ssh:prod-01")
        XCTAssertEqual(BookmarksPluginNew.namespace(for: docker), "docker:app")
    }
}
