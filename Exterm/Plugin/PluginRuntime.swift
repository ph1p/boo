import Foundation
import os.log

/// Protocol for plugins that participate in the two-phase enrich/react cycle.
@MainActor
protocol ExtermPlugin: AnyObject {
    var pluginID: String { get }

    /// Phase 1: Contribute data to the shared context.
    /// Called on the main thread. Must complete quickly (< 2ms per plugin).
    func enrich(context: EnrichmentContext)

    /// Phase 2: Read the frozen context and update cached state/UI.
    /// Called on the main thread. Must complete quickly (< 2ms per plugin).
    func react(context: TerminalContext)
}

/// Default implementations — plugins only need to implement the phases they use.
extension ExtermPlugin {
    func enrich(context: EnrichmentContext) {}
    func react(context: TerminalContext) {}
}

/// Lifecycle event that triggered the plugin cycle.
enum PluginCycleReason {
    case focusChanged
    case cwdChanged
    case titleChanged
    case processChanged
    case remoteSessionChanged
    case workspaceSwitched
}

/// Orchestrates the two-phase plugin cycle.
/// Runs on every terminal state change. All plugins participate.
/// ADR-1 + ADR-2: TerminalContext flows through enrich → freeze → react.
@MainActor
final class PluginRuntime {
    private(set) var plugins: [ExtermPlugin] = []
    private let logger = Logger(subsystem: "com.exterm", category: "PluginRuntime")

    /// The most recent frozen context after a cycle completes.
    private(set) var lastContext: TerminalContext?

    func register(_ plugin: ExtermPlugin) {
        plugins.append(plugin)
    }

    func unregister(pluginID: String) {
        plugins.removeAll { $0.pluginID == pluginID }
    }

    /// Run the two-phase cycle.
    /// Returns the frozen TerminalContext produced by the cycle.
    @discardableResult
    func runCycle(baseContext: TerminalContext, reason: PluginCycleReason) -> TerminalContext {
        let start = CFAbsoluteTimeGetCurrent()

        // Phase 1: Enrich
        let disabled = AppSettings.shared.disabledPluginIDsSet
        let active = plugins.filter { !disabled.contains($0.pluginID) }
        let enrichment = EnrichmentContext(base: baseContext)
        for plugin in active {
            plugin.enrich(context: enrichment)
        }

        // Phase boundary: freeze
        let frozenContext = enrichment.freeze()

        // Phase 2: React
        for plugin in active {
            plugin.react(context: frozenContext)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 16 {
            logger.warning("Plugin cycle took \(elapsed, format: .fixed(precision: 1))ms (budget: 16ms)")
        }

        lastContext = frozenContext
        return frozenContext
    }
}
