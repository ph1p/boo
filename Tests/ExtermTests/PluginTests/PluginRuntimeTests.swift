import XCTest
@testable import Exterm

// MARK: - Test Plugins

@MainActor
final class EnrichTestPlugin: ExtermPlugin {
    let pluginID = "enrich-test"
    var enrichCalled = false
    var reactCalled = false
    var enrichOrder = 0
    var reactOrder = 0

    static var callCounter = 0

    func enrich(context: EnrichmentContext) {
        enrichCalled = true
        Self.callCounter += 1
        enrichOrder = Self.callCounter
        context.gitBranch = "enriched-branch"
        context.gitRepoRoot = "/enriched/root"
        context.gitIsDirty = true
        context.gitChangedFileCount = 3
    }

    func react(context: TerminalContext) {
        reactCalled = true
        Self.callCounter += 1
        reactOrder = Self.callCounter
    }
}

@MainActor
final class ReactTestPlugin: ExtermPlugin {
    let pluginID = "react-test"
    var receivedBranch: String?
    var receivedIsDirty: Bool?
    var enrichOrder = 0
    var reactOrder = 0

    func enrich(context: EnrichmentContext) {
        EnrichTestPlugin.callCounter += 1
        enrichOrder = EnrichTestPlugin.callCounter
    }

    func react(context: TerminalContext) {
        EnrichTestPlugin.callCounter += 1
        reactOrder = EnrichTestPlugin.callCounter
        receivedBranch = context.gitContext?.branch
        receivedIsDirty = context.gitContext?.isDirty
    }
}

// MARK: - Tests

@MainActor
final class PluginRuntimeTests: XCTestCase {

    private func makeBaseContext() -> TerminalContext {
        TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
    }

    func testTwoPhaseOrdering() {
        let runtime = PluginRuntime()
        EnrichTestPlugin.callCounter = 0

        let enrichPlugin = EnrichTestPlugin()
        let reactPlugin = ReactTestPlugin()
        runtime.register(enrichPlugin)
        runtime.register(reactPlugin)

        runtime.runCycle(baseContext: makeBaseContext(), reason: .focusChanged)

        // All enrich calls happen before all react calls
        XCTAssertTrue(enrichPlugin.enrichCalled)
        XCTAssertTrue(enrichPlugin.reactCalled)
        XCTAssertTrue(enrichPlugin.enrichOrder < enrichPlugin.reactOrder)
        XCTAssertTrue(reactPlugin.enrichOrder < reactPlugin.reactOrder)

        // Enrich phases complete before react phases start
        let maxEnrich = max(enrichPlugin.enrichOrder, reactPlugin.enrichOrder)
        let minReact = min(enrichPlugin.reactOrder, reactPlugin.reactOrder)
        XCTAssertTrue(maxEnrich < minReact, "All enrich must complete before any react")
    }

    func testEnrichedDataFlowsToReact() {
        let runtime = PluginRuntime()
        let enrichPlugin = EnrichTestPlugin()
        let reactPlugin = ReactTestPlugin()
        runtime.register(enrichPlugin)
        runtime.register(reactPlugin)

        runtime.runCycle(baseContext: makeBaseContext(), reason: .focusChanged)

        // React plugin should see data enriched by enrich plugin
        XCTAssertEqual(reactPlugin.receivedBranch, "enriched-branch")
        XCTAssertEqual(reactPlugin.receivedIsDirty, true)
    }

    func testContextFrozenAfterCycle() {
        let runtime = PluginRuntime()
        let enrichPlugin = EnrichTestPlugin()
        runtime.register(enrichPlugin)

        let result = runtime.runCycle(baseContext: makeBaseContext(), reason: .focusChanged)

        // The returned context has enriched data
        XCTAssertEqual(result.gitContext?.branch, "enriched-branch")
        XCTAssertEqual(result.gitContext?.changedFileCount, 3)

        // lastContext matches
        XCTAssertEqual(runtime.lastContext, result)
    }

    func testEmptyRuntime() {
        let runtime = PluginRuntime()
        let base = makeBaseContext()
        let result = runtime.runCycle(baseContext: base, reason: .focusChanged)

        // No plugins → base context returned as-is
        XCTAssertEqual(result, base)
    }

    func testUnregister() {
        let runtime = PluginRuntime()
        let plugin = EnrichTestPlugin()
        runtime.register(plugin)
        XCTAssertEqual(runtime.plugins.count, 1)

        runtime.unregister(pluginID: "enrich-test")
        XCTAssertEqual(runtime.plugins.count, 0)
    }
}

// MARK: - EnrichmentContext Tests

@MainActor
final class EnrichmentContextTests: XCTestCase {

    func testFreezeProducesImmutableContext() {
        let base = TerminalContext(
            terminalID: UUID(),
            cwd: "/home/user",
            remoteSession: .ssh(host: "server"),
            gitContext: nil,
            processName: "vim",
            paneCount: 2,
            tabCount: 1
        )
        let enrichment = EnrichmentContext(base: base)
        enrichment.gitBranch = "feature"
        enrichment.gitRepoRoot = "/home/user/repo"
        enrichment.gitIsDirty = true
        enrichment.gitChangedFileCount = 5

        let frozen = enrichment.freeze()

        XCTAssertEqual(frozen.terminalID, base.terminalID)
        XCTAssertEqual(frozen.cwd, "/home/user")
        XCTAssertEqual(frozen.processName, "vim")
        XCTAssertEqual(frozen.paneCount, 2)
        XCTAssertEqual(frozen.gitContext?.branch, "feature")
        XCTAssertEqual(frozen.gitContext?.repoRoot, "/home/user/repo")
        XCTAssertEqual(frozen.gitContext?.isDirty, true)
        XCTAssertEqual(frozen.gitContext?.changedFileCount, 5)
        if case .ssh(let host) = frozen.remoteSession {
            XCTAssertEqual(host, "server")
        } else {
            XCTFail("Expected SSH session")
        }
    }

    func testSetDataAfterFreezeIgnored() {
        let base = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        let enrichment = EnrichmentContext(base: base)
        enrichment.setData("before", forKey: "test")
        _ = enrichment.freeze()
        enrichment.setData("after", forKey: "test")

        // Data set before freeze is retained, data after is ignored
        XCTAssertEqual(enrichment.getData(forKey: "test") as? String, "before")
    }

    func testEnrichmentPreservesBaseContext() {
        let id = UUID()
        let base = TerminalContext(
            terminalID: id,
            cwd: "/projects",
            remoteSession: .docker(container: "app"),
            gitContext: TerminalContext.GitContext(branch: "main", repoRoot: "/projects", isDirty: false, changedFileCount: 0),
            processName: "node",
            paneCount: 3,
            tabCount: 2
        )
        let enrichment = EnrichmentContext(base: base)

        // Without modifying anything, freeze should produce equivalent context
        let frozen = enrichment.freeze()
        XCTAssertEqual(frozen.terminalID, id)
        XCTAssertEqual(frozen.cwd, "/projects")
        XCTAssertEqual(frozen.processName, "node")
        XCTAssertEqual(frozen.gitContext?.branch, "main")
    }
}
