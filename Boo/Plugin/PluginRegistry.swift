import Foundation
import os.log

/// Manages registered plugins and orchestrates the lifecycle cycle.
/// Ties together TerminalContext, EnrichmentContext, WhenClauseEvaluator,
/// and all registered BooPluginProtocol instances.
@MainActor
final class PluginRegistry {
    private(set) var plugins: [BooPluginProtocol] = []
    private let runtime = PluginRuntime()
    private let logger = Logger(subsystem: "com.boo", category: "PluginRegistry")
    private let pluginServices: PluginServices = HostPluginServices()

    /// The most recent context after a cycle.
    var lastContext: TerminalContext? { runtime.lastContext }

    /// The most recent cycle result — used for change detection.
    private var lastCycleVisibleIDs: Set<String>?
    private var lastCycleContext: TerminalContext?

    /// Callback for plugins to request a cycle rerun.
    var onRequestCycleRerun: (() -> Void)?

    /// Force the next cycle to report contextChanged/visibilityChanged as true.
    func clearChangeDetection() {
        lastCycleContext = nil
        lastCycleVisibleIDs = nil
    }

    /// Unified actions distributed to all plugins on set.
    var actions: PluginActions? {
        didSet {
            for i in plugins.indices {
                plugins[i].actions = actions
            }
        }
    }

    /// Host actions distributed to all plugins on set.
    /// Deprecated: use `actions` instead.
    var hostActions: PluginHostActions? {
        didSet {
            for i in plugins.indices {
                plugins[i].hostActions = hostActions
            }
        }
    }

    // MARK: - Registration

    func register(_ plugin: BooPluginProtocol) {
        let p = plugin
        p.hostActions = hostActions
        p.actions = actions
        p.services = pluginServices
        p.onRequestCycleRerun = { [weak self] in
            self?.onRequestCycleRerun?()
        }
        plugins.append(p)
        runtime.register(p)
        logger.info("Registered plugin: \(plugin.pluginID)")
    }

    func unregister(pluginID: String) {
        plugins.removeAll { $0.pluginID == pluginID }
        runtime.unregister(pluginID: pluginID)
        logger.info("Unregistered plugin: \(pluginID)")
    }

    // MARK: - Activate / Deactivate

    /// Plugins without a sidebar tab that are currently activated.
    private var activeSidebarlessPluginIDs: Set<String> = []

    /// Notify a plugin it has become active (sidebar tab selected or statusbar-only plugin visible).
    /// Plugins use this to start background work (watchers, sockets).
    func activatePlugin(_ pluginID: String) {
        plugin(for: pluginID)?.pluginDidActivate()
    }

    /// Notify a plugin it has been deactivated (sidebar tab deselected or statusbar-only plugin hidden).
    /// Plugins use this to stop background work and release resources.
    func deactivatePlugin(_ pluginID: String) {
        plugin(for: pluginID)?.pluginDidDeactivate()
    }

    /// Activate/deactivate plugins that are visible but have no sidebar tab.
    /// These plugins live only in the status bar and need explicit lifecycle management.
    func reconcileSidebarlessPlugins(visibleIDs: Set<String>, sidebarTabIDs: Set<String>) {
        let sidebarlessVisible = visibleIDs.subtracting(sidebarTabIDs)

        // Activate newly visible sidebarless plugins
        for id in sidebarlessVisible where !activeSidebarlessPluginIDs.contains(id) {
            activatePlugin(id)
        }
        // Deactivate sidebarless plugins that are no longer visible
        for id in activeSidebarlessPluginIDs where !sidebarlessVisible.contains(id) {
            deactivatePlugin(id)
        }

        activeSidebarlessPluginIDs = sidebarlessVisible
    }

    // MARK: - Cycle

    /// Run the full plugin cycle and return visible plugin IDs.
    @discardableResult
    func runCycle(baseContext: TerminalContext, reason: PluginCycleReason) -> PluginCycleResult {
        let frozenContext = runtime.runCycle(baseContext: baseContext, reason: reason)

        // Evaluate when-clauses to determine visible plugins
        let visiblePlugins = plugins.filter { $0.isVisible(for: frozenContext) }
        let visibleIDs = Set(visiblePlugins.map(\.pluginID))

        // Build per-plugin contexts and collect status bar content
        let theme = ThemeSnapshot(from: AppSettings.shared.theme)
        let density = AppSettings.shared.sidebarDensity
        let fontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
        let statusBarContents: [(String, StatusBarContent)] = visiblePlugins.compactMap { plugin in
            let ctx = PluginContext(
                terminal: frozenContext,
                theme: theme,
                density: density,
                settings: PluginSettingsReader(pluginID: plugin.pluginID),
                fontScale: fontScale
            )
            guard let content = plugin.makeStatusBarContent(context: ctx) else { return nil }
            return (plugin.pluginID, content)
        }
        let contextChanged = lastCycleContext != frozenContext
        let visibilityChanged = lastCycleVisibleIDs != visibleIDs

        lastCycleContext = frozenContext
        lastCycleVisibleIDs = visibleIDs

        return PluginCycleResult(
            context: frozenContext,
            visiblePluginIDs: visibleIDs,
            statusBarContents: statusBarContents,
            contextChanged: contextChanged,
            visibilityChanged: visibilityChanged
        )
    }

    /// Collect sidebar tabs contributed by all registered plugins for the given context.
    func contributedSidebarTabs(terminal: TerminalContext) -> [SidebarTab] {
        plugins.compactMap { plugin in
            guard plugin.isVisible(for: terminal) else { return nil }
            let ctx = buildPluginContext(for: plugin.pluginID, terminal: terminal)
            return plugin.makeSidebarTab(context: ctx)
        }
    }

    /// Collect menu contributions from all visible plugins.
    func collectMenuContributions(context: TerminalContext) -> [PluginMenuContribution] {
        plugins.compactMap { plugin in
            guard plugin.isVisible(for: context) else { return nil }
            return plugin.menuContributions()
        }
    }

    /// Dispatch a menu action to the target plugin.
    func dispatchMenuAction(pluginID: String, actionName: String, context: TerminalContext) {
        plugin(for: pluginID)?.handleMenuAction(actionName, context: context)
    }

    /// Build a PluginContext for a specific plugin from a TerminalContext.
    /// Always reads live settings so font/theme changes are reflected immediately.
    func buildPluginContext(for pluginID: String, terminal: TerminalContext) -> PluginContext {
        PluginContext(
            terminal: terminal,
            theme: ThemeSnapshot(from: AppSettings.shared.theme),
            density: AppSettings.shared.sidebarDensity,
            settings: PluginSettingsReader(pluginID: pluginID),
            fontScale: SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
        )
    }

    // MARK: - Lifecycle Events

    /// Plugins that are not disabled by the user.
    private var activePlugins: [BooPluginProtocol] {
        let disabled = AppSettings.shared.disabledPluginIDsSet
        return plugins.filter { !disabled.contains($0.pluginID) }
    }

    func notifyCwdChanged(newPath: String, context: TerminalContext) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.cwdChanged) {
            plugin.cwdChanged(newPath: newPath, context: context)
        }
    }

    func notifyRemoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.remoteSessionChanged) {
            plugin.remoteSessionChanged(session: session, context: context)
        }
    }

    func notifyProcessChanged(name: String, context: TerminalContext) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.processChanged) {
            plugin.processChanged(name: name, context: context)
        }
    }

    func notifyTerminalCreated(terminalID: UUID) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.terminalCreated) {
            plugin.terminalCreated(terminalID: terminalID)
        }
    }

    func notifyTerminalClosed(terminalID: UUID) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.terminalClosed) {
            plugin.terminalClosed(terminalID: terminalID)
        }
    }

    func notifyFocusChanged(terminalID: UUID, context: TerminalContext) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.focusChanged) {
            plugin.terminalFocusChanged(terminalID: terminalID, context: context)
        }
    }

    func notifyRemoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        for plugin in activePlugins where plugin.subscribedEvents.contains(.remoteDirectoryListed) {
            plugin.remoteDirectoryListed(path: path, entries: entries)
        }
    }

    // MARK: - Query

    func plugin(for id: String) -> BooPluginProtocol? {
        plugins.first { $0.pluginID == id }
    }

    /// Register the default built-in plugins.
    func registerBuiltins() {
        register(LocalFileTreePlugin())
        register(RemoteFileTreePlugin())
        register(GitPlugin())
        register(ClaudeCodePlugin())
        register(CodexPlugin())
        register(OpenCodePlugin())
        register(DockerPluginNew())
        register(BookmarksPluginNew())
        register(SnippetsPlugin())
        register(SystemInfoPlugin())
        register(DebugPlugin())
    }

}

/// Result of a plugin cycle execution.
struct PluginCycleResult {
    let context: TerminalContext
    let visiblePluginIDs: Set<String>
    let statusBarContents: [(pluginID: String, content: StatusBarContent)]
    /// Whether the terminal context changed since the last cycle.
    let contextChanged: Bool
    /// Whether the set of visible plugins changed since the last cycle.
    let visibilityChanged: Bool
}
