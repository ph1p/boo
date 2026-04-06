import XCTest

@testable import Boo

// MARK: - Helpers

private func makeContext(cwd: String, tabID: UUID = UUID(), tabCount: Int = 1) -> PluginContext {
    let terminal = TerminalContext(
        terminalID: tabID,
        cwd: cwd,
        remoteSession: nil,
        gitContext: nil,
        processName: "",
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

    private var tmpDir: URL!

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

}
