import Foundation
import os.log

/// Manages registered plugins and orchestrates the lifecycle cycle.
/// Ties together TerminalContext, EnrichmentContext, WhenClauseEvaluator,
/// and all registered ExtermPluginProtocol instances.
@MainActor
final class PluginRegistry {
    private(set) var plugins: [ExtermPluginProtocol] = []
    private let runtime = PluginRuntime()
    private let logger = Logger(subsystem: "com.exterm", category: "PluginRegistry")
    private let pluginServices: PluginServices = HostPluginServices()

    /// The most recent context after a cycle.
    var lastContext: TerminalContext? { runtime.lastContext }

    /// The most recent PluginContext built during a cycle (for sidebar rebuild).
    private(set) var lastPluginContexts: [String: PluginContext] = [:]

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

    func register(_ plugin: ExtermPluginProtocol) {
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
        var contexts: [String: PluginContext] = [:]
        let statusBarContents: [(String, StatusBarContent)] = visiblePlugins.compactMap { plugin in
            let ctx = PluginContext(
                terminal: frozenContext,
                theme: theme,
                density: density,
                settings: PluginSettingsReader(pluginID: plugin.pluginID)
            )
            contexts[plugin.pluginID] = ctx
            guard let content = plugin.makeStatusBarContent(context: ctx) else { return nil }
            return (plugin.pluginID, content)
        }
        let contextChanged = lastCycleContext != frozenContext
        let visibilityChanged = lastCycleVisibleIDs != visibleIDs

        lastPluginContexts = contexts
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

    /// Build a PluginContext for a specific plugin from a TerminalContext.
    func buildPluginContext(for pluginID: String, terminal: TerminalContext) -> PluginContext {
        if let cached = lastPluginContexts[pluginID], cached.terminal == terminal {
            return cached
        }
        return PluginContext(
            terminal: terminal,
            theme: ThemeSnapshot(from: AppSettings.shared.theme),
            density: AppSettings.shared.sidebarDensity,
            settings: PluginSettingsReader(pluginID: pluginID)
        )
    }

    // MARK: - Lifecycle Events

    /// Plugins that are not disabled by the user.
    private var activePlugins: [ExtermPluginProtocol] {
        let disabled = AppSettings.shared.disabledPluginIDs
        return plugins.filter { !disabled.contains($0.pluginID) }
    }

    func notifyCwdChanged(newPath: String, context: TerminalContext) {
        for plugin in activePlugins {
            plugin.cwdChanged(newPath: newPath, context: context)
        }
    }

    func notifyRemoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        for plugin in activePlugins {
            plugin.remoteSessionChanged(session: session, context: context)
        }
    }

    func notifyProcessChanged(name: String, context: TerminalContext) {
        for plugin in activePlugins {
            plugin.processChanged(name: name, context: context)
        }
    }

    func notifyTerminalCreated(terminalID: UUID) {
        for plugin in activePlugins {
            plugin.terminalCreated(terminalID: terminalID)
        }
    }

    func notifyTerminalClosed(terminalID: UUID) {
        for plugin in activePlugins {
            plugin.terminalClosed(terminalID: terminalID)
        }
    }

    func notifyFocusChanged(terminalID: UUID, context: TerminalContext) {
        for plugin in activePlugins {
            plugin.terminalFocusChanged(terminalID: terminalID, context: context)
        }
    }

    func notifyRemoteDirectoryListed(path: String, entries: [RemoteExplorer.RemoteEntry]) {
        for plugin in activePlugins {
            plugin.remoteDirectoryListed(path: path, entries: entries)
        }
    }

    // MARK: - Query

    func plugin(for id: String) -> ExtermPluginProtocol? {
        plugins.first { $0.pluginID == id }
    }

    /// Register the default built-in plugins.
    func registerBuiltins() {
        register(LocalFileTreePlugin())
        register(RemoteFileTreePlugin())
        register(GitPlugin())
        register(AIAgentPlugin())
        register(DockerPluginNew())
        register(BookmarksPluginNew())
        register(SystemInfoPlugin())
    }

    /// Auto-register status bar toggle icons from plugin manifests.
    /// Skips file-tree plugins (they have a dedicated FileTreeIconSegment).
    func registerStatusBarIcons(in statusBar: StatusBarView) {
        let disabled = AppSettings.shared.disabledPluginIDs
        for plugin in plugins
        where plugin.manifest.capabilities?.sidebarPanel == true && !disabled.contains(plugin.pluginID) {
            let m = plugin.manifest
            if m.id == "file-tree-local" || m.id == "file-tree-remote" { continue }
            let priority = m.statusBar?.priority ?? 50
            let segment = PluginIconSegment(
                pluginID: m.id,
                sfSymbol: m.icon,
                label: m.name,
                priority: priority
            )
            statusBar.registerPlugin(segment)
        }
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
