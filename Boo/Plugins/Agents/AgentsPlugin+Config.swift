import AppKit
import Foundation

// MARK: - Agent Config Scan

extension AgentsPlugin {
    func scanAgentConfig(cwd: String?) {
        guard let cwd = cwd else { return }

        withProjectRoot(cwd: cwd) { [weak self] projectRoot in
            guard let self else { return }
            // Record the cwd before the TTL early-return: `makeSidebarTab` gates its
            // scan dispatch on `currentCwd != context.terminal.cwd`, so leaving it
            // unset would re-dispatch both scans on every call for the whole TTL window.
            self.currentCwd = cwd
            // Root equality alone made this permanently sticky — a CLAUDE.md or skill
            // added to the same project never showed up. Re-scan once the TTL expires.
            guard self.configScan.shouldScan(root: projectRoot, ttl: Self.scanTTL) else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                let config = Self.detectAgentConfig(cwd: cwd, projectRoot: projectRoot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // A TTL re-scan that finds nothing new must not trigger a sidebar
                    // rebuild — that would restart the rebuild/focus churn the debounce
                    // exists to prevent.
                    let unchanged =
                        self.agentConfig.configFiles.map(\.path) == config.configFiles.map(\.path)
                        && self.agentConfig.skills.map(\.path) == config.skills.map(\.path)
                    self.agentConfig = config
                    if !unchanged { self.onRequestCycleRerun?() }
                }
            }
        }
    }

    /// Pass `projectRoot` when the caller already resolved it — `findAgentProjectRoot`
    /// walks up to 20 levels x 4 markers of `fileExists`, and the scan path has it.
    nonisolated static func detectAgentConfig(cwd: String, projectRoot: String? = nil) -> AgentConfig {
        let fm = FileManager.default
        var config = AgentConfig()
        let home = fm.homeDirectoryForCurrentUser.path
        let projectRoot = projectRoot ?? findAgentProjectRoot(from: cwd, markers: projectMarkers) ?? cwd

        for adapter in AgentKind.adapters {
            for spec in adapter.configFiles {
                checkFile(
                    fm: fm, root: spec.global ? home : projectRoot, rel: spec.path, name: spec.name, icon: spec.icon,
                    scope: spec.global ? "global" : "project", provider: adapter.kind, into: &config)
            }
            adapter.scanExtraConfig(root: projectRoot, home: home, into: &config)
        }

        return config
    }

    nonisolated private static func checkFile(
        fm: FileManager, root: String, rel: String, name: String,
        icon: String, scope: String, provider: AgentKind, into config: inout AgentConfig
    ) {
        let fullPath = (root as NSString).appendingPathComponent(rel)
        if fm.fileExists(atPath: fullPath) {
            if !config.configFiles.contains(where: { $0.path == fullPath }) {
                config.configFiles.append(
                    AgentConfig.ConfigFile(name: name, path: fullPath, icon: icon, scope: scope, provider: provider))
            }
        }
    }
}
