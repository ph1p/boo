import SwiftUI

/// Built-in hosts plugin: the `Host` entries of `~/.ssh/config`, with open
/// sessions and last connection times.
@MainActor
final class HostsPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: "hosts",
        name: "Hosts",
        version: "1.0.0",
        icon: "server.rack",
        description: "SSH hosts from ~/.ssh/config",
        when: "!process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    var subscribedEvents: Set<PluginEvent> { [.remoteSessionChanged, .terminalClosed] }

    /// `HostsPanelView` observes `HostsStore`; only the font scale is baked in.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: [context.fontScale.generationKey])
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        AnyView(HostsPanelView(fontScale: context.fontScale))
    }

    func pluginDidActivate() {
        HostsStore.shared.start()
        HostsStore.shared.refreshLive()
    }

    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext) {
        HostsStore.shared.refreshLive()
    }

    func terminalClosed(terminalID: UUID) {
        // The tab leaves the model after this callback.
        DispatchQueue.main.async { HostsStore.shared.refreshLive() }
    }
}
