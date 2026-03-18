import SwiftUI

/// Content for a status bar segment declared by a plugin.
struct StatusBarContent {
    let text: String
    let icon: String?       // SF Symbol name
    let tint: DSLTint?
    let accessibilityLabel: String?
}

/// Unified plugin protocol for both built-in and external plugins.
/// Combines sidebar, status bar, and lifecycle into one protocol.
/// Replaces the separate SidebarPlugin + StatusBarPlugin protocols.
@MainActor
protocol ExtermPluginProtocol: ExtermPlugin {
    /// Plugin manifest (inline for built-in plugins, parsed from JSON for external).
    var manifest: PluginManifest { get }

    /// When-clause expression (parsed from manifest). nil = always visible.
    var whenClause: WhenClauseNode? { get }

    // MARK: - UI

    /// Create the detail panel content view for the current context.
    /// Built-in plugins return SwiftUI views; script plugins return DSL-rendered views.
    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView?

    /// Create status bar content for the current context.
    /// Return nil if this plugin doesn't contribute to the status bar.
    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent?

    /// Dynamic section title for the sidebar panel.
    /// Return nil to use the static manifest name.
    func sectionTitle(context: TerminalContext) -> String?

    /// Whether the sidebar should add an outer NSScrollView around the detail view.
    /// Plugins that already contain their own scroll view should return false.
    var prefersOuterScrollView: Bool { get }

    // MARK: - Granular Lifecycle Callbacks

    func cwdChanged(newPath: String, context: TerminalContext)
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext)
    func processChanged(name: String, context: TerminalContext)
    func terminalCreated(terminalID: UUID)
    func terminalClosed(terminalID: UUID)
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext)
}

/// Default no-op implementations for all optional methods.
extension ExtermPluginProtocol {
    var whenClause: WhenClauseNode? { nil }

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? { nil }
    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? { nil }
    func sectionTitle(context: TerminalContext) -> String? { nil }
    var prefersOuterScrollView: Bool { true }

    func cwdChanged(newPath: String, context: TerminalContext) {}
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {}
    func processChanged(name: String, context: TerminalContext) {}
    func terminalCreated(terminalID: UUID) {}
    func terminalClosed(terminalID: UUID) {}
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {}
}

/// Evaluates whether a plugin should be visible given a terminal context.
extension ExtermPluginProtocol {
    func isVisible(for context: TerminalContext) -> Bool {
        guard let clause = whenClause else { return true }
        return WhenClauseEvaluator.evaluate(clause, context: context)
    }
}
