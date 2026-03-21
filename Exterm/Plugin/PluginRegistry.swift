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

    /// The most recent context after a cycle.
    var lastContext: TerminalContext? { runtime.lastContext }

    /// Callback for plugins to request a cycle rerun.
    var onRequestCycleRerun: (() -> Void)?

    /// Host actions distributed to all plugins on set.
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

        // Collect status bar content
        let statusBarContents: [(String, StatusBarContent)] = visiblePlugins.compactMap { plugin in
            guard let content = plugin.makeStatusBarContent(context: frozenContext) else { return nil }
            return (plugin.pluginID, content)
        }

        return PluginCycleResult(
            context: frozenContext,
            visiblePluginIDs: visibleIDs,
            statusBarContents: statusBarContents
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

    // MARK: - Query

    func plugin(for id: String) -> ExtermPluginProtocol? {
        plugins.first { $0.pluginID == id }
    }

    /// Register the default built-in plugins.
    func registerBuiltins() {
        register(LocalFileTreePlugin())
        register(RemoteFileTreePlugin())
        register(GitPlugin())
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
}
