import SwiftUI

/// Events that plugins can subscribe to. Plugins declare which events they
/// care about via `subscribedEvents`. The registry only delivers callbacks
/// for subscribed events — like tmux's control mode subscriptions.
enum PluginEvent: Hashable {
    case cwdChanged
    case processChanged
    case remoteSessionChanged
    case focusChanged
    case terminalCreated
    case terminalClosed
    case remoteDirectoryListed
}

/// Content for a status bar segment declared by a plugin.
struct StatusBarContent {
    let text: String
    let icon: String?  // SF Symbol name
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

    // MARK: - UI (PluginContext)

    /// Create the detail panel content view using the structured plugin context.
    func makeDetailView(context: PluginContext) -> AnyView?

    /// Create status bar content using the structured plugin context.
    func makeStatusBarContent(context: PluginContext) -> StatusBarContent?

    /// Dynamic section title using the structured plugin context.
    func sectionTitle(context: PluginContext) -> String?

    // MARK: - UI (Legacy — TerminalContext + actionHandler)

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

    /// Unified action dispatch for terminal and system operations.
    var actions: PluginActions? { get set }

    /// Injectable services for system/shell calls.
    var services: PluginServices? { get set }

    /// Host-provided action closures (paste path, open in tab/pane, etc.).
    /// Deprecated: use `actions` instead.
    var hostActions: PluginHostActions? { get set }

    /// Called by the plugin when it wants the host to re-run a plugin cycle
    /// (e.g. after Docker containers change or git status updates).
    var onRequestCycleRerun: (() -> Void)? { get set }

    // MARK: - Event Subscriptions

    /// Events this plugin subscribes to. Only subscribed events trigger lifecycle
    /// callbacks — unsubscribed events are skipped entirely. This prevents plugins
    /// from doing unnecessary work when data they don't care about changes.
    /// Default: all events (backward compatible). Override to narrow scope.
    var subscribedEvents: Set<PluginEvent> { get }

    // MARK: - Granular Lifecycle Callbacks

    func cwdChanged(newPath: String, context: TerminalContext)
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext)
    func processChanged(name: String, context: TerminalContext)
    func terminalCreated(terminalID: UUID)
    func terminalClosed(terminalID: UUID)
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext)

    /// Called when a remote directory listing arrives from the bridge.
    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry])

    // MARK: - Activation Lifecycle

    /// Called when the plugin is opened in the sidebar (status bar click or tab switch).
    /// Use this to start background work (watchers, sockets, timers).
    func pluginDidActivate()

    /// Called when the plugin is closed from the sidebar.
    /// Use this to stop all background work and release resources.
    func pluginDidDeactivate()
}

/// Default no-op implementations for all optional methods.
extension ExtermPluginProtocol {
    /// Default: derive pluginID from manifest.id to avoid redundant declarations.
    var pluginID: String { manifest.id }

    /// Default: parse whenClause from manifest.when string.
    /// Returns nil if manifest.when is nil (always visible).
    var whenClause: WhenClauseNode? {
        guard let when = manifest.when else { return nil }
        return try? WhenClauseParser.parse(when)
    }

    // PluginContext-based defaults forward to legacy TerminalContext methods.
    func makeDetailView(context: PluginContext) -> AnyView? { nil }
    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? { nil }
    func sectionTitle(context: PluginContext) -> String? { nil }

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? { nil }
    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? { nil }
    func sectionTitle(context: TerminalContext) -> String? { nil }
    var prefersOuterScrollView: Bool { true }

    // Note: actions, services, hostActions, onRequestCycleRerun, and subscribedEvents
    // have NO default implementation. Every plugin must declare them explicitly.
    // This ensures plugins are intentional about what events they consume.

    func cwdChanged(newPath: String, context: TerminalContext) {}
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {}
    func processChanged(name: String, context: TerminalContext) {}
    func terminalCreated(terminalID: UUID) {}
    func terminalClosed(terminalID: UUID) {}
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {}
    func remoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {}

    func pluginDidActivate() {}
    func pluginDidDeactivate() {}
}

/// Evaluates whether a plugin should be visible given a terminal context.
extension ExtermPluginProtocol {
    func isVisible(for context: TerminalContext) -> Bool {
        if !AppSettings.shared.isPluginEnabled(pluginID) { return false }
        guard let clause = whenClause else { return true }
        return WhenClauseEvaluator.evaluate(clause, context: context)
    }
}
