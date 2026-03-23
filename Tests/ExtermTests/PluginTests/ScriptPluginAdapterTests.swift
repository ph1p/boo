import XCTest

@testable import Exterm

@MainActor
final class ScriptPluginAdapterTests: XCTestCase {

    private func makeManifest(
        id: String = "test-plugin",
        when: String? = nil,
        statusBarTemplate: String? = nil
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            name: "Test Plugin",
            version: "1.0.0",
            icon: "star",
            description: "Test",
            when: when,
            runtime: nil,
            capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
            statusBar: PluginManifest.StatusBarManifest(position: "left", priority: 50, template: statusBarTemplate),
            settings: nil
        )
    }

    private func makeContext(
        gitBranch: String? = nil,
        remote: RemoteSessionType? = nil
    ) -> TerminalContext {
        let git: TerminalContext.GitContext?
        if let branch = gitBranch {
            git = TerminalContext.GitContext(
                branch: branch, repoRoot: "/repo", isDirty: false, changedFileCount: 0, stagedCount: 0,
                aheadCount: 0, behindCount: 0, lastCommitShort: nil)
        } else {
            git = nil
        }
        return TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: remote,
            gitContext: git,
            processName: "vim",
            paneCount: 1,
            tabCount: 1
        )
    }

    private func makePluginContext(
        terminal: TerminalContext,
        pluginID: String = "test-plugin"
    ) -> PluginContext {
        PluginContext(
            terminal: terminal,
            theme: ThemeSnapshot(from: AppSettings.shared.theme),
            density: .comfortable,
            settings: PluginSettingsReader(pluginID: pluginID)
        )
    }

    func testAdapterConformsToPlugin() {
        let adapter = ScriptPluginAdapter(manifest: makeManifest(), folderPath: "/tmp/test-plugin")
        XCTAssertEqual(adapter.pluginID, "test-plugin")
        XCTAssertEqual(adapter.manifest.name, "Test Plugin")
    }

    func testWhenClauseParsing() {
        let adapter = ScriptPluginAdapter(
            manifest: makeManifest(when: "git.active"),
            folderPath: "/tmp"
        )
        XCTAssertNotNil(adapter.whenClause)

        let noWhen = ScriptPluginAdapter(
            manifest: makeManifest(when: nil),
            folderPath: "/tmp"
        )
        XCTAssertNil(noWhen.whenClause)
    }

    func testVisibilityEvaluation() {
        let adapter = ScriptPluginAdapter(
            manifest: makeManifest(when: "git.active"),
            folderPath: "/tmp"
        )
        let withGit = makeContext(gitBranch: "main")
        let noGit = makeContext()

        XCTAssertTrue(adapter.isVisible(for: withGit))
        XCTAssertFalse(adapter.isVisible(for: noGit))
    }

    func testStatusBarContentWithTemplate() {
        let adapter = ScriptPluginAdapter(
            manifest: makeManifest(statusBarTemplate: "{git.branch} ({process.name})"),
            folderPath: "/tmp"
        )
        let tc = makeContext(gitBranch: "feature")
        let ctx = makePluginContext(terminal: tc)
        let content = adapter.makeStatusBarContent(context: ctx)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.text, "feature (vim)")
    }

    func testStatusBarContentWithoutTemplate() {
        let adapter = ScriptPluginAdapter(
            manifest: makeManifest(statusBarTemplate: nil),
            folderPath: "/tmp"
        )
        let ctx = makePluginContext(terminal: makeContext())
        let content = adapter.makeStatusBarContent(context: ctx)
        XCTAssertEqual(content?.text, "Test Plugin")
    }

    func testDetailViewShowsLoadingWhenNoCache() {
        let adapter = ScriptPluginAdapter(manifest: makeManifest(), folderPath: "/tmp/nonexistent")
        let ctx = makePluginContext(terminal: makeContext())
        let view = adapter.makeDetailView(context: ctx)
        // Should return a loading view since no script has been executed
        XCTAssertNotNil(view)
    }
}
