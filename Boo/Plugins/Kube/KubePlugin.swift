import SwiftUI

/// Built-in Kubernetes plugin (off by default): pods, workloads, jobs,
/// services and ingresses of the current kube context/namespace, watched
/// while the panel is active (only the expanded sections).
@MainActor
final class KubePlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: KubeStore.pluginID,
        name: "Kubernetes",
        version: "1.0.0",
        icon: "helm",
        description: "Pods, workloads, jobs, services and ingresses of the current kube context",
        when: "!process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    var subscribedEvents: Set<PluginEvent> { [] }

    /// `KubePanelView` observes `KubeStore`; only the font scale is baked in.
    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: [context.fontScale.generationKey])
    }

    func makeDetailView(context: PluginContext) -> AnyView? {
        AnyView(KubePanelView(fontScale: context.fontScale))
    }

    func pluginDidActivate() {
        KubeStore.shared.startWatching()
    }

    func pluginDidDeactivate() {
        KubeStore.shared.stopWatching()
    }

    func checkAvailability() async -> Bool {
        // Off main: waiting for the login-shell PATH can take seconds at launch.
        await Task.detached(priority: .utility) { KubeStore.findKubectl() != nil }.value
    }
}
