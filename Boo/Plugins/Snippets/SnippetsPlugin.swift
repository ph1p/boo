import SwiftUI

/// Built-in snippets plugin. Lets users save and paste frequently-used
/// terminal commands from the sidebar.
@MainActor
final class SnippetsPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "snippets",
        name: "Snippets",
        version: "1.0.0",
        icon: "text.page",
        description: "Save and paste frequently-used terminal commands",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    var subscribedEvents: Set<PluginEvent> { [] }

    /// `SnippetsPanelView` observes the snippet store itself, so the list stays live without
    /// a rootView swap — and a swap would reset its editing state and scroll offset. Only
    /// `fontScale`, the one value baked in below, needs to force a rebuild.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: ["fontScale", context.fontScale.generationKey])
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        let act = actions
        return AnyView(
            SnippetsPanelView(
                fontScale: context.fontScale,
                onRun: { command in
                    act?.exec(command)
                },
                onPaste: { command in
                    act?.sendToTerminal?(command)
                }
            )
        )
    }
}
