import SwiftUI

/// Built-in task runner: lists the package.json scripts, make targets, just
/// recipes and cargo / SwiftPM commands of the focused terminal's project and
/// runs them in a new tab.
@MainActor
final class TasksPlugin: BooPluginProtocol {
    static let pluginID = "tasks"

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: TasksPlugin.pluginID,
        name: "Tasks",
        version: "1.0.0",
        icon: "play.square.stack",
        description: "Run package.json scripts, make, just, cargo and swift tasks",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    var subscribedEvents: Set<PluginEvent> { [.cwdChanged] }

    /// The panel observes the run store itself; only the folder and the font
    /// scale need a rebuild.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: [
            context.terminal.cwd, context.terminal.gitContext?.repoRoot ?? "",
            context.terminal.remoteSession == nil ? "local" : "remote", context.fontScale.generationKey
        ])
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        let terminal = context.terminal
        let act = actions
        return AnyView(
            TasksPanelView(
                cwd: terminal.remoteSession == nil ? terminal.cwd : "",
                repoRoot: terminal.gitContext?.repoRoot,
                fontScale: context.fontScale,
                onRun: { task, root in
                    act?.openTab?(TaskRunStore.shared.start(task, in: root))
                },
                onRunHere: { task in act?.exec(task.command) }
            )
        )
    }
}
