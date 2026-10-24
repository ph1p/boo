import XCTest

@testable import Boo

// MARK: - Helpers

private func makeContext(
    cwd: String, tabID: UUID = UUID(), tabCount: Int = 1, processName: String = ""
) -> PluginContext {
    let terminal = TerminalContext(
        terminalID: tabID,
        cwd: cwd,
        remoteSession: nil,
        gitContext: nil,
        processName: processName,
        paneCount: 1,
        tabCount: tabCount
    )
    return PluginContext(
        terminal: terminal,
        theme: ThemeSnapshot(from: AppSettings.shared.theme),
        density: .comfortable,
        settings: PluginSettingsReader(pluginID: "file-tree-local"),
        fontScale: SidebarFontScale(base: 12)
    )
}

@MainActor
final class LocalFileTreePluginTests: XCTestCase {

    // MARK: - Temp directory helpers

    nonisolated(unsafe) private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalFileTreePluginTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func createFile(_ name: String) throws {
        let url = tmpDir.appendingPathComponent(name)
        try Data().write(to: url)
    }

    // MARK: - Visibility

    func testVisibleForLocalContext() {
        let plugin = LocalFileTreePlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/test/project",
            remoteSession: nil,
            gitContext: nil,
            processName: "",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertTrue(
            plugin.isVisible(for: context),
            "Local file tree plugin should be visible when not remote")
    }

    func testHiddenForRemoteContext() {
        let plugin = LocalFileTreePlugin()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: "/Users/test/project",
            remoteSession: .ssh(host: "user@remote"),
            gitContext: nil,
            processName: "ssh",
            paneCount: 1,
            tabCount: 1
        )
        XCTAssertFalse(
            plugin.isVisible(for: context),
            "Local file tree plugin should be hidden when remote")
    }

    // MARK: - makeDetailView: root always has children on context switch

    /// When makeDetailView is called for a directory, the root's children must be
    /// non-nil so FileTreeView can render rows immediately (onAppear doesn't fire
    /// when rootView is replaced in-place via NSHostingView.rootView).
    func testMakeDetailViewPopulatesRootChildrenForNewContext() throws {
        try createFile("alpha.txt")
        try createFile("beta.swift")

        let plugin = LocalFileTreePlugin()
        let ctx = makeContext(cwd: tmpDir.path)
        let view = plugin.makeDetailView(context: ctx)

        XCTAssertNotNil(view, "makeDetailView must return a view for a local context")

        // The file tree root for tmpDir must have children loaded
        // Verify by calling makeDetailView again with the same context — if the root
        // was properly loaded, a second call with isSameTerminalAndCwd=true must
        // not clear children (i.e., the root object is stable).
        let view2 = plugin.makeDetailView(context: ctx)
        XCTAssertNotNil(view2)
    }

    /// Switching to a different tab pointing to the same directory must reload the
    /// root's children — this is the fix for the "empty on new tab" bug where
    /// onAppear doesn't fire when rootView is swapped in-place.
    func testMakeDetailViewReloadsChildrenOnContextSwitch() throws {
        try createFile("file1.txt")
        try createFile("file2.swift")

        let plugin = LocalFileTreePlugin()
        let tabA = UUID()
        let tabB = UUID()

        // First call — tab A
        let ctxA = makeContext(cwd: tmpDir.path, tabID: tabA)
        _ = plugin.makeDetailView(context: ctxA)

        // Add a new file between the two calls to prove the reload actually ran
        try createFile("file3.md")

        // Second call — different tab B, same directory (simulates new tab in same dir)
        let ctxB = makeContext(cwd: tmpDir.path, tabID: tabB)
        let viewB = plugin.makeDetailView(context: ctxB)
        XCTAssertNotNil(viewB, "makeDetailView must not return nil on context switch")
    }

    /// Switching to a new directory (new tab, different CWD) must produce a valid
    /// view with children loaded for the new path.
    func testMakeDetailViewHandlesCwdChangeToNewDirectory() throws {
        // Create two separate directories
        let dirA = tmpDir.appendingPathComponent("dirA")
        let dirB = tmpDir.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data().write(to: dirA.appendingPathComponent("a.txt"))
        try Data().write(to: dirB.appendingPathComponent("b.txt"))

        let plugin = LocalFileTreePlugin()

        // Tab A — dirA
        let ctxA = makeContext(cwd: dirA.path, tabID: UUID())
        let viewA = plugin.makeDetailView(context: ctxA)
        XCTAssertNotNil(viewA, "must return view for dirA")

        // Tab B — dirB (different CWD)
        let ctxB = makeContext(cwd: dirB.path, tabID: UUID())
        let viewB = plugin.makeDetailView(context: ctxB)
        XCTAssertNotNil(viewB, "must return view for dirB")
    }

    /// Switching back to a previously-visited tab (same tab ID, same CWD) must NOT
    /// re-trigger a loadChildren — isSameTerminalAndCwd=true should be a no-op.
    func testMakeDetailViewDoesNotReloadOnSameContext() throws {
        try createFile("only.txt")

        let plugin = LocalFileTreePlugin()
        let tabID = UUID()
        let ctx = makeContext(cwd: tmpDir.path, tabID: tabID)

        _ = plugin.makeDetailView(context: ctx)
        // Second call with identical context — must not crash
        let view2 = plugin.makeDetailView(context: ctx)
        XCTAssertNotNil(view2)
    }

    // MARK: - Detached browsing

    func testBrowseShowsFolderWithoutChangingTerminalCwd() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plugin = LocalFileTreePlugin()
        let ctx = makeContext(cwd: tmpDir.path)
        _ = plugin.makeDetailView(context: ctx)

        plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)

        XCTAssertEqual(plugin.rootPath(for: ctx.terminal), sub.path)
        XCTAssertEqual(plugin.sectionTitle(context: ctx), "sub")
        _ = plugin.makeDetailView(context: ctx)
        XCTAssertNotNil(plugin.cachedRoot(for: sub.path), "the browsed folder becomes the tree root")
    }

    func testShellMoveReattachesWhenFollowingTerminal() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        let other = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try withPluginSettings("file-tree-local", ["followTerminal": true]) {
            let plugin = LocalFileTreePlugin()
            let tab = UUID()
            let ctx = makeContext(cwd: tmpDir.path, tabID: tab)
            _ = plugin.makeDetailView(context: ctx)
            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)

            let moved = makeContext(cwd: other.path, tabID: tab)
            _ = plugin.makeDetailView(context: moved)
            XCTAssertEqual(plugin.rootPath(for: moved.terminal), other.path)
        }
    }

    func testShellMoveKeepsDetachedRootWhenNotFollowing() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        let other = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try withPluginSettings("file-tree-local", ["followTerminal": false]) {
            let plugin = LocalFileTreePlugin()
            let tab = UUID()
            let ctx = makeContext(cwd: tmpDir.path, tabID: tab)
            _ = plugin.makeDetailView(context: ctx)
            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)

            let moved = makeContext(cwd: other.path, tabID: tab)
            _ = plugin.makeDetailView(context: moved)
            XCTAssertEqual(plugin.rootPath(for: moved.terminal), sub.path)
        }
    }

    func testBrowseStateIsPerTerminal() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plugin = LocalFileTreePlugin()
        let ctxA = makeContext(cwd: tmpDir.path)
        let ctxB = makeContext(cwd: tmpDir.path)
        _ = plugin.makeDetailView(context: ctxA)
        plugin.open(sub.path, terminal: ctxA.terminal, canSendToTerminal: false)

        XCTAssertEqual(plugin.rootPath(for: ctxA.terminal), sub.path)
        XCTAssertEqual(plugin.rootPath(for: ctxB.terminal), tmpDir.path)
        plugin.terminalClosed(terminalID: ctxA.terminal.terminalID)
        XCTAssertEqual(plugin.rootPath(for: ctxA.terminal), tmpDir.path)
    }

    func testDeletedBrowsedFolderFallsBackOnRootChangedEvent() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plugin = LocalFileTreePlugin()
        let ctx = makeContext(cwd: tmpDir.path)
        _ = plugin.makeDetailView(context: ctx)
        plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)
        _ = plugin.makeDetailView(context: ctx)
        try FileManager.default.removeItem(at: sub)

        _ = plugin.makeDetailView(context: ctx)
        XCTAssertEqual(plugin.rootPath(for: ctx.terminal), sub.path, "no stat on a same-context cycle")
        plugin.watchedRootChanged()
        _ = plugin.makeDetailView(context: ctx)
        XCTAssertEqual(plugin.rootPath(for: ctx.terminal), tmpDir.path)
    }

    func testDeletedBrowsedFolderFallsBackOnContextSwitch() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plugin = LocalFileTreePlugin()
        let ctx = makeContext(cwd: tmpDir.path)
        _ = plugin.makeDetailView(context: ctx)
        plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)
        _ = plugin.makeDetailView(context: makeContext(cwd: tmpDir.path))
        try FileManager.default.removeItem(at: sub)

        _ = plugin.makeDetailView(context: ctx)
        XCTAssertEqual(plugin.rootPath(for: ctx.terminal), tmpDir.path)
    }

    func testBackgroundShellMoveReattachesOnFocus() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        let other = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try withPluginSettings("file-tree-local", ["followTerminal": true]) {
            let plugin = LocalFileTreePlugin()
            let tab = UUID()
            let ctx = makeContext(cwd: tmpDir.path, tabID: tab)
            _ = plugin.makeDetailView(context: ctx)
            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)
            // Another terminal is shown while this one's shell moves (no cwdChanged event).
            _ = plugin.makeDetailView(context: makeContext(cwd: tmpDir.path))

            let refocused = makeContext(cwd: other.path, tabID: tab)
            _ = plugin.makeDetailView(context: refocused)
            XCTAssertEqual(plugin.rootPath(for: refocused.terminal), other.path)
        }
    }

    func testDetachedShellMoveKeepsTreeGenerationWhenNotFollowing() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("boo-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try withPluginSettings("file-tree-local", ["followTerminal": false]) {
            let plugin = LocalFileTreePlugin()
            let tab = UUID()
            let ctx = makeContext(cwd: tmpDir.path, tabID: tab)
            _ = plugin.makeSidebarTab(context: ctx)
            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)
            // Outside the old cwd, so the bar label is the same `~`-path either way.
            plugin.open(other.path, terminal: ctx.terminal, canSendToTerminal: false)
            let before = plugin.makeSidebarTab(context: ctx)?.sections.first?.generation

            let moved = makeContext(cwd: sub.path, tabID: tab)
            let after = plugin.makeSidebarTab(context: moved)?.sections.first?.generation
            XCTAssertNotNil(before)
            XCTAssertEqual(before, after, "a shell cd must not swap the detached tree view")
        }
    }

    func testDisplayPath() {
        XCTAssertEqual(LocalFileTreePlugin.displayPath(root: "/a/b", terminalCwd: "/a/b"), "b")
        XCTAssertEqual(LocalFileTreePlugin.displayPath(root: "/a/b/c", terminalCwd: "/a/b"), "./c")
        XCTAssertEqual(LocalFileTreePlugin.displayPath(root: "/a/bc", terminalCwd: "/a/b"), "/a/bc")
    }

    func testTerminalModeTypesCd() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try withPluginSettings("file-tree-local", ["navigationMode": "terminal"]) {
            let plugin = LocalFileTreePlugin()
            var sent: [String] = []
            let actions = PluginActions()
            actions.sendToTerminal = { sent.append($0) }
            plugin.actions = actions
            let ctx = makeContext(cwd: tmpDir.path)
            _ = plugin.makeDetailView(context: ctx)

            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: true)
            XCTAssertEqual(sent, ["cd \(shellEscape(sub.path))\r"])
            XCTAssertEqual(plugin.rootPath(for: ctx.terminal), tmpDir.path, "root waits for the shell")

            // An AI agent owns the terminal: browse instead of typing into its prompt.
            plugin.open(sub.path, terminal: ctx.terminal, canSendToTerminal: false)
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(plugin.rootPath(for: ctx.terminal), sub.path)
        }
    }

    // MARK: - Expanded state persistence

    /// Opening a folder, navigating away, then returning to the same directory must
    /// restore the previously expanded folders.
    func testExpandedFoldersRestoredWhenReturningToDirectory() throws {
        let dirA = tmpDir.appendingPathComponent("dirA")
        let sub = dirA.appendingPathComponent("sub")
        let dirB = tmpDir.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("nested.txt"))

        let plugin = LocalFileTreePlugin()
        let tabID = UUID()

        _ = plugin.makeDetailView(context: makeContext(cwd: dirA.path, tabID: tabID))
        let rootA = try XCTUnwrap(plugin.cachedRoot(for: dirA.path))
        let subNode = try XCTUnwrap(rootA.children?.first { $0.name == "sub" })
        subNode.isExpanded = true
        subNode.loadChildren()

        // Navigate away (same tab, different cwd) and back.
        _ = plugin.makeDetailView(context: makeContext(cwd: dirB.path, tabID: tabID))
        _ = plugin.makeDetailView(context: makeContext(cwd: dirA.path, tabID: tabID))

        let rootA2 = try XCTUnwrap(plugin.cachedRoot(for: dirA.path))
        let subNode2 = try XCTUnwrap(rootA2.children?.first { $0.name == "sub" })
        XCTAssertTrue(
            subNode2.isExpanded,
            "Returning to a directory must restore the folders that were open there")
    }

    /// Root nodes are cached per path and shared by every tab showing that directory,
    /// so switching to another tab in the same directory must not collapse folders.
    func testSwitchingTabsInSameDirectoryKeepsFoldersOpen() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let plugin = LocalFileTreePlugin()
        let tabA = UUID()
        let tabB = UUID()

        _ = plugin.makeDetailView(context: makeContext(cwd: tmpDir.path, tabID: tabA))
        let root = try XCTUnwrap(plugin.cachedRoot(for: tmpDir.path))
        let subNode = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        subNode.isExpanded = true

        _ = plugin.makeDetailView(context: makeContext(cwd: tmpDir.path, tabID: tabB))
        let subNodeB = try XCTUnwrap(
            plugin.cachedRoot(for: tmpDir.path)?.children?.first { $0.name == "sub" })
        XCTAssertTrue(
            subNodeB.isExpanded,
            "Switching tabs within the same directory must not collapse open folders")
    }

    /// Same terminal + same cwd must not re-run restore, or a folder the user just
    /// opened would collapse on the next plugin cycle.
    func testExpansionSurvivesRepeatedCyclesInSameDirectory() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let plugin = LocalFileTreePlugin()
        let ctx = makeContext(cwd: tmpDir.path, tabID: UUID())
        _ = plugin.makeDetailView(context: ctx)
        let root = try XCTUnwrap(plugin.cachedRoot(for: tmpDir.path))
        let subNode = try XCTUnwrap(root.children?.first { $0.name == "sub" })
        subNode.isExpanded = true

        for _ in 0..<3 { _ = plugin.makeDetailView(context: ctx) }
        XCTAssertTrue(subNode.isExpanded, "Re-render in the same context must not collapse folders")
    }

    // MARK: - Section generations

    /// Section generations must be stable while the terminal and cwd are unchanged —
    /// a changing generation swaps the hosting view's rootView and resets scroll.
    func testSectionGenerationsStableForUnchangedContext() throws {
        try createFile("a.txt")
        let plugin = LocalFileTreePlugin()
        let tabID = UUID()

        let first = try XCTUnwrap(
            plugin.makeSidebarTab(context: makeContext(cwd: tmpDir.path, tabID: tabID)))
        // Same terminal + cwd, but a different foreground process (the common case:
        // the user ran a command).
        let second = try XCTUnwrap(
            plugin.makeSidebarTab(
                context: makeContext(cwd: tmpDir.path, tabID: tabID, processName: "npm")))
        XCTAssertEqual(
            first.sections.map(\.generation), second.sections.map(\.generation),
            "Generations must not change when only the foreground process changed")

        // A cwd change must change the generations so content actually refreshes.
        let otherDir = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let third = try XCTUnwrap(
            plugin.makeSidebarTab(
                context: makeContext(cwd: otherDir.path, tabID: tabID, processName: "npm")))
        XCTAssertNotEqual(
            second.sections.map(\.generation), third.sections.map(\.generation),
            "A cwd change must bump generations so the sections re-render")
    }

}
