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
