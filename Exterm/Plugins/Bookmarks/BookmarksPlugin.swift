import SwiftUI

/// Built-in bookmarks plugin. Wraps BookmarksPanelView into the
/// unified plugin protocol. Per-host namespacing for remote sessions.
@MainActor
final class BookmarksPluginNew: ExtermPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "bookmarks",
        name: "Bookmarks",
        version: "1.0.0",
        icon: "bookmark",
        description: "Saved directory bookmarks",
        when: "!process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 20, template: nil),
        settings: nil
    )

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        let count = BookmarkService.shared.bookmarks.count
        let text = count > 0 ? "\(count)" : "Bookmarks"
        return StatusBarContent(
            text: text,
            icon: "bookmark",
            tint: nil,
            accessibilityLabel: "Bookmarks: \(count) saved"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        let tc = context.terminal
        let ns = Self.namespace(for: tc)
        let cwd = tc.isRemote ? (tc.remoteCwd ?? tc.cwd) : tc.cwd
        let act = actions
        return AnyView(
            BookmarksPanelView(
                namespace: ns,
                onBookmarkSelected: { path in
                    act?.handle(DSLAction(type: "cd", path: path, command: nil, text: nil))
                },
                onBookmarkCurrent: {
                    let service = BookmarkService.shared
                    if service.contains(path: cwd, namespace: ns) {
                        if let bm = service.bookmarks(for: ns).first(where: { $0.path == cwd }) {
                            service.remove(id: bm.id)
                        }
                    } else {
                        service.addCurrentDirectory(cwd, namespace: ns)
                    }
                },
                currentDirectory: cwd
            ))
    }

    /// Returns the bookmark namespace for the current context.
    static func namespace(for context: TerminalContext) -> String {
        guard let session = context.remoteSession else { return "local" }
        return "\(session.envType):\(session.displayName)"
    }
}
