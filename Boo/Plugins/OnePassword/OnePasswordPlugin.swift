import SwiftUI

/// Built-in 1Password plugin (off by default, needs the `op` CLI): search
/// items, copy or type their secrets, insert `op://` references.
@MainActor
final class OnePasswordPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: OnePasswordStore.pluginID,
        name: "1Password",
        version: "1.0.0",
        icon: "key",
        description: "Search 1Password items, copy or type secrets, insert op:// references",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: [
            PluginManifest.SettingManifest(
                key: OnePasswordStore.linkOpenModeKey, type: .string,
                label: "Open item websites in",
                defaultValue: AnyCodableValue(LinkOpenMode.browserTab.rawValue),
                options: nil, group: nil, choices: LinkOpenMode.choices)
        ]
    )

    var subscribedEvents: Set<PluginEvent> { [] }

    /// The item list scrolls on its own below a fixed header; nested in the
    /// sidebar's outer scroll view it got no height and would not scroll.
    var scrollsItself: Bool { true }

    /// `OnePasswordPanelView` observes `OnePasswordStore`; only the font scale is baked in.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: [context.fontScale.generationKey])
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        OnePasswordStore.shared.openInBrowserTab = { [weak self] url in
            self?.actions?.openTab?(.browser(url: url))
        }
        return AnyView(OnePasswordPanelView(fontScale: context.fontScale))
    }

    func checkAvailability() async -> Bool {
        // Off main: waiting for the login-shell PATH can take seconds at launch.
        await Task.detached(priority: .utility) { OnePasswordStore.findOp() != nil }.value
    }
}
