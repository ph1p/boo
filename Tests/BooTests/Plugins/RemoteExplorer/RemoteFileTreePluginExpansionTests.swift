import XCTest

@testable import Boo

// MARK: - Helpers

private func makeContext(
    remoteCwd: String,
    host: String = "devbox",
    tabID: UUID = UUID(),
    processName: String = "ssh"
) -> PluginContext {
    let terminal = TerminalContext(
        terminalID: tabID,
        cwd: "/Users/test",
        remoteSession: .ssh(host: host),
        remoteCwd: remoteCwd,
        gitContext: nil,
        processName: processName,
        paneCount: 1,
        tabCount: 1
    )
    return PluginContext(
        terminal: terminal,
        theme: ThemeSnapshot(from: AppSettings.shared.theme),
        density: .comfortable,
        settings: PluginSettingsReader(pluginID: "file-tree-remote"),
        fontScale: SidebarFontScale(base: 12, fontName: "")
    )
}

/// The remote explorer's half of the expansion-persistence fix: open folders are keyed by
/// `host:path`, not by terminal, because root nodes are cached per root and shared by every
/// tab showing that directory. Mirrors `LocalFileTreePluginTests`.
@MainActor
final class RemoteFileTreePluginExpansionTests: XCTestCase {

    /// Populate a root's children without going near SSH.
    private func seed(
        _ plugin: RemoteFileTreePlugin, _ ctx: PluginContext, names: [String]
    ) throws -> RemoteFileTreeNode {
        let root = try XCTUnwrap(
            plugin.cachedRoot(for: ctx.terminal),
            "makeDetailView must have cached a root for this context")
        root.applyEntries(names.map { RemoteExplorer.RemoteEntry(name: $0, isDirectory: true) })
        return root
    }

    private func child(_ root: RemoteFileTreeNode, _ name: String) throws -> RemoteFileTreeNode {
        try XCTUnwrap(root.children?.first { $0.name == name })
    }

    // MARK: - Same context

    /// A re-render in the same context (the common case: the foreground process changed)
    /// must not re-run restore, or a folder the user just opened collapses.
    func testExpansionSurvivesRepeatedCyclesInSameContext() throws {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let ctx = makeContext(remoteCwd: "/srv/app", tabID: tabID)

        _ = plugin.makeDetailView(context: ctx)
        let root = try seed(plugin, ctx, names: ["logs", "conf"])
        let logs = try child(root, "logs")
        logs.isExpanded = true

        for _ in 0..<3 { _ = plugin.makeDetailView(context: ctx) }
        XCTAssertTrue(
            logs.isExpanded, "A same-context re-render must not collapse open folders")
    }

    /// A foreground-process change is a same-context cycle, not a switch.
    func testExpansionSurvivesProcessChange() throws {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let ctx = makeContext(remoteCwd: "/srv/app", tabID: tabID, processName: "ssh")

        _ = plugin.makeDetailView(context: ctx)
        let root = try seed(plugin, ctx, names: ["logs"])
        let logs = try child(root, "logs")
        logs.isExpanded = true

        _ = plugin.makeDetailView(
            context: makeContext(remoteCwd: "/srv/app", tabID: tabID, processName: "htop"))
        XCTAssertTrue(logs.isExpanded)
    }

    // MARK: - Round trip

    /// Navigating away and back to the same remote directory must restore what was open.
    func testExpandedFoldersRestoredWhenReturningToDirectory() throws {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let ctxA = makeContext(remoteCwd: "/srv/app", tabID: tabID)
        let ctxB = makeContext(remoteCwd: "/srv/other", tabID: tabID)

        _ = plugin.makeDetailView(context: ctxA)
        let rootA = try seed(plugin, ctxA, names: ["logs", "conf"])
        let logs = try child(rootA, "logs")
        logs.isExpanded = true

        // Away…
        _ = plugin.makeDetailView(context: ctxB)
        _ = try seed(plugin, ctxB, names: ["unrelated"])

        // Leaving must have snapshotted what was open under this root's own key. Assert on
        // the state rather than on the node: coming back re-expands the root, and the
        // resulting listing is an async SSH call that has no master in a test.
        let saved = try XCTUnwrap(
            plugin.savedExpandedPaths(for: ctxA.terminal),
            "Leaving a root must snapshot its open folders")
        XCTAssertTrue(
            saved.contains(logs.remotePath),
            "The open folder must be recorded under the root it belongs to")

        // …and back: the root node is the cached one, and restore feeds it those paths.
        _ = plugin.makeDetailView(context: ctxA)
        let rootAgain = try XCTUnwrap(plugin.cachedRoot(for: ctxA.terminal))
        XCTAssertTrue(rootAgain === rootA, "Returning must reuse the cached root")
        XCTAssertTrue(
            rootAgain.isExpanded,
            "Returning to a remote directory must restore the folders that were open there")
    }

    /// Root nodes are shared per root, so switching to another tab on the same host+path
    /// must not collapse anything.
    func testSwitchingTabsOnSameRootKeepsFoldersOpen() throws {
        let plugin = RemoteFileTreePlugin()
        let ctxA = makeContext(remoteCwd: "/srv/app", tabID: UUID())
        let ctxB = makeContext(remoteCwd: "/srv/app", tabID: UUID())

        _ = plugin.makeDetailView(context: ctxA)
        let root = try seed(plugin, ctxA, names: ["logs"])
        let logs = try child(root, "logs")
        logs.isExpanded = true

        _ = plugin.makeDetailView(context: ctxB)
        let rootB = try XCTUnwrap(plugin.cachedRoot(for: ctxB.terminal))
        XCTAssertTrue(
            rootB === root, "The same host+path must resolve to the same cached root")
        XCTAssertTrue(
            try child(rootB, "logs").isExpanded,
            "Switching tabs within the same remote directory must not collapse folders")
    }

    /// The same path on a different host is a different tree, and its expansion state must
    /// not leak across hosts.
    func testExpansionIsKeyedPerHost() throws {
        let plugin = RemoteFileTreePlugin()
        let alpha = makeContext(remoteCwd: "/srv", host: "alpha", tabID: UUID())
        let beta = makeContext(remoteCwd: "/srv", host: "beta", tabID: UUID())

        _ = plugin.makeDetailView(context: alpha)
        let rootAlpha = try seed(plugin, alpha, names: ["logs"])
        let node = try child(rootAlpha, "logs")
        node.isExpanded = true

        _ = plugin.makeDetailView(context: beta)
        let rootBeta = try seed(plugin, beta, names: ["logs"])
        XCTAssertFalse(
            try child(rootBeta, "logs").isExpanded,
            "Expansion state must not cross hosts")
    }

    // MARK: - Cleanup

    /// Closing a terminal drops its cwd mapping, but the expansion state is keyed by root
    /// and outlives the terminal on purpose — reopening the same directory restores it.
    func testExpansionOutlivesTheTerminalThatOpenedIt() throws {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let ctx = makeContext(remoteCwd: "/srv/app", tabID: tabID)

        _ = plugin.makeDetailView(context: ctx)
        let root = try seed(plugin, ctx, names: ["logs"])
        let node = try child(root, "logs")
        node.isExpanded = true

        plugin.terminalClosed(terminalID: tabID)

        // A brand-new terminal on the same root.
        let reopened = makeContext(remoteCwd: "/srv/app", tabID: UUID())
        _ = plugin.makeDetailView(context: reopened)
        let rootAgain = try XCTUnwrap(plugin.cachedRoot(for: reopened.terminal))
        XCTAssertTrue(
            try child(rootAgain, "logs").isExpanded,
            "Expansion is keyed by root, so a new terminal on that root inherits it")
    }
}
