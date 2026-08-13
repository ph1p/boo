import XCTest

@testable import Boo

// MARK: - Helpers

private func makeContext(
    pluginID: String,
    cwd: String = "/Users/test/project",
    tabID: UUID = UUID(),
    processName: String = "",
    remoteSession: RemoteSessionType? = nil,
    remoteCwd: String? = nil,
    fontScale: SidebarFontScale = SidebarFontScale(base: 12, fontName: "")
) -> PluginContext {
    let terminal = TerminalContext(
        terminalID: tabID,
        cwd: cwd,
        remoteSession: remoteSession,
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
        settings: PluginSettingsReader(pluginID: pluginID),
        fontScale: fontScale
    )
}

/// Covers `sectionGeneration(context:)`, the value the host compares to decide whether to
/// swap a section's hosted `rootView`. A swap resets scroll position and SwiftUI view
/// state, so a stable generation is what keeps a sidebar panel from jumping; a constant
/// one, on the other hand, leaves stale rows on screen.
@MainActor
final class SectionGenerationTests: XCTestCase {

    // MARK: - Default

    /// A plugin that has not opted in must never claim its content is unchanged — the
    /// failure mode of a constant default is invisible (stale rows, no error), so the
    /// default takes the cheap side and forces a rebuild.
    func testDefaultGenerationChangesEveryCall() {
        let plugin = SystemInfoPlugin()
        let ctx = makeContext(pluginID: plugin.manifest.id)
        let first = plugin.sectionGeneration(context: ctx)
        let second = plugin.sectionGeneration(context: ctx)
        XCTAssertNotEqual(
            first, second,
            "The unopted-in default must assume the content changed")
    }

    /// The counter is shared, so two plugins never collide on a value either.
    func testDefaultGenerationIsUniqueAcrossPlugins() {
        let a = SystemInfoPlugin()
        let b = DebugPlugin()
        let genA = a.sectionGeneration(context: makeContext(pluginID: a.manifest.id))
        let genB = b.sectionGeneration(context: makeContext(pluginID: b.manifest.id))
        XCTAssertNotEqual(genA, genB)
    }

    /// The default reaches the section the default `makeSidebarTab` builds — the constant
    /// `0` that used to sit there is what this replaced.
    func testDefaultSidebarTabCarriesAChangingGeneration() throws {
        let plugin = SystemInfoPlugin()
        let ctx = makeContext(pluginID: plugin.manifest.id)
        let first = try XCTUnwrap(plugin.makeSidebarTab(context: ctx))
        let second = try XCTUnwrap(plugin.makeSidebarTab(context: ctx))
        XCTAssertNotEqual(
            first.sections.map(\.generation), second.sections.map(\.generation),
            "A plugin that refreshes from its own state must get a fresh generation")
    }

    // MARK: - Snippets

    /// Snippets' panel observes the snippet store itself, so an unchanged context must
    /// reuse the view — otherwise a half-typed snippet edit would be discarded.
    func testSnippetsGenerationStableAcrossUnrelatedContextChange() {
        let plugin = SnippetsPlugin()
        let tabID = UUID()
        let first = plugin.sectionGeneration(
            context: makeContext(pluginID: plugin.manifest.id, tabID: tabID))
        let second = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, cwd: "/elsewhere", tabID: tabID,
                processName: "npm"))
        XCTAssertEqual(
            first, second,
            "Snippets do not depend on cwd or the foreground process")
    }

    func testSnippetsGenerationChangesWithFontScale() {
        let plugin = SnippetsPlugin()
        let small = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, fontScale: SidebarFontScale(base: 11, fontName: "")))
        let large = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, fontScale: SidebarFontScale(base: 16, fontName: "")))
        XCTAssertNotEqual(small, large, "The font scale is baked into the view, so it must rebuild")
    }

    func testSnippetsGenerationChangesWithFontName() {
        let plugin = SnippetsPlugin()
        let a = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, fontScale: SidebarFontScale(base: 12, fontName: "")))
        let b = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id,
                fontScale: SidebarFontScale(base: 12, fontName: "Menlo")))
        XCTAssertNotEqual(a, b, "Both fields of the scale must reach the generation key")
    }

    // MARK: - Bookmarks

    /// A foreground-process change must not swap the bookmarks view and reset its scroll.
    func testBookmarksGenerationStableForProcessChange() {
        let plugin = BookmarksPluginNew()
        let tabID = UUID()
        let first = plugin.sectionGeneration(
            context: makeContext(pluginID: plugin.manifest.id, tabID: tabID))
        let second = plugin.sectionGeneration(
            context: makeContext(pluginID: plugin.manifest.id, tabID: tabID, processName: "vim"))
        XCTAssertEqual(first, second)
    }

    /// The current directory drives the "bookmark this folder" affordance, so it must
    /// force a rebuild.
    func testBookmarksGenerationChangesWithCwd() {
        let plugin = BookmarksPluginNew()
        let tabID = UUID()
        let first = plugin.sectionGeneration(
            context: makeContext(pluginID: plugin.manifest.id, cwd: "/a", tabID: tabID))
        let second = plugin.sectionGeneration(
            context: makeContext(pluginID: plugin.manifest.id, cwd: "/b", tabID: tabID))
        XCTAssertNotEqual(first, second)
    }

    /// Bookmarks are namespaced per host, so the same path on two hosts is different
    /// content.
    func testBookmarksGenerationChangesWithRemoteHost() {
        let plugin = BookmarksPluginNew()
        let first = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: .ssh(host: "alpha"),
                remoteCwd: "/srv"))
        let second = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: .ssh(host: "beta"),
                remoteCwd: "/srv"))
        XCTAssertNotEqual(first, second, "Bookmark namespaces are per host")
    }

    // MARK: - Remote file tree

    /// The remote tree view observes its root node, so a listing arriving must not swap
    /// the view — that would collapse the tree the user just opened.
    func testRemoteTreeGenerationStableForProcessChange() {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let session = RemoteSessionType.ssh(host: "devbox")
        let first = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, tabID: tabID, remoteSession: session,
                remoteCwd: "/home/user/project"))
        let second = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, tabID: tabID, processName: "htop",
                remoteSession: session, remoteCwd: "/home/user/project"))
        XCTAssertEqual(
            first, second,
            "A foreground-process change must not rebuild the remote tree")
    }

    func testRemoteTreeGenerationChangesWithRemotePath() {
        let plugin = RemoteFileTreePlugin()
        let session = RemoteSessionType.ssh(host: "devbox")
        let first = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: session, remoteCwd: "/srv/one"))
        let second = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: session, remoteCwd: "/srv/two"))
        XCTAssertNotEqual(first, second, "A different root is different content")
    }

    func testRemoteTreeGenerationChangesWithHost() {
        let plugin = RemoteFileTreePlugin()
        let first = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: .ssh(host: "alpha"),
                remoteCwd: "/srv"))
        let second = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, remoteSession: .ssh(host: "beta"),
                remoteCwd: "/srv"))
        XCTAssertNotEqual(first, second, "The same path on another host is another tree")
    }

    /// The AI flag is baked into the row actions, so the rows must rebuild when it flips.
    func testRemoteTreeGenerationChangesWithAIAgentFlag() {
        let plugin = RemoteFileTreePlugin()
        let tabID = UUID()
        let session = RemoteSessionType.ssh(host: "devbox")
        let plain = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, tabID: tabID, processName: "bash",
                remoteSession: session, remoteCwd: "/srv"))
        let ai = plugin.sectionGeneration(
            context: makeContext(
                pluginID: plugin.manifest.id, tabID: tabID, processName: "claude",
                remoteSession: session, remoteCwd: "/srv"))
        XCTAssertNotEqual(plain, ai, "Row actions differ under an AI agent")
    }
}
