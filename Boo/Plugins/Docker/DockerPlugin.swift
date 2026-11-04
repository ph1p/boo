import SwiftUI

@MainActor
func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    if !NSPasteboard.general.setString(text, forType: .string) {
        BooAlert.showTransient("Could not copy to clipboard")
    }
}

/// Built-in Docker plugin. Shows running containers when Docker is available.
/// Available locally (not in remote sessions).
@MainActor
final class DockerPluginNew: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    init() {
        DockerService.shared.addContainersObserver(self) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onRequestCycleRerun?()
            }
        }
        applySocketPathSetting()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let topic = notification.userInfo?["topic"] as? String
            Task { @MainActor [weak self] in
                guard topic == "plugins" else { return }
                let oldSocket = DockerService.shared.socketPath
                self?.applySocketPathSetting()
                guard DockerService.shared.socketPath != oldSocket else { return }
                DockerService.shared.restartWatching()
                self?.onRequestCycleRerun?()
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        DockerService.shared.removeContainersObserver(self)
        DockerService.shared.stopWatching(self)
    }

    // MARK: - Activation Lifecycle

    func pluginDidActivate() {
        applySocketPathSetting()
        DockerService.shared.startWatching(self)
    }

    func pluginDidDeactivate() {
        DockerService.shared.stopWatching(self)
    }

    let manifest = PluginManifest(
        id: "docker",
        name: "Docker",
        version: "1.0.0",
        icon: "shippingbox",
        description: "Running Docker containers",
        when: "!remote && !process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 10, template: nil),
        settings: [
            PluginManifest.SettingManifest(
                key: "socketPath", type: .string,
                label: "Docker socket path",
                defaultValue: AnyCodableValue(""), options: "dockerSocket")
        ]
    )

    var subscribedEvents: Set<PluginEvent> { [] }

    private func applySocketPathSetting() {
        let path = AppSettings.shared.pluginString("docker", "socketPath", default: "")
        DockerService.shared.detectDocker(explicitPath: path.isEmpty ? nil : path)
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        if DockerService.shared.connectionError != nil { return "Docker (disconnected)" }
        let containers = DockerService.shared.containers
        guard !containers.isEmpty else { return nil }
        let running = containers.filter { $0.state == .running }.count
        return "Docker (\(running)/\(containers.count))"
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        if let error = DockerService.shared.connectionError {
            return StatusBarContent(
                text: "disconnected", icon: "shippingbox", tint: .error,
                accessibilityLabel: "Docker: \(error)")
        }
        let containers = DockerService.shared.containers
        guard !containers.isEmpty else { return nil }
        let running = containers.filter { $0.state == .running }.count
        let text =
            running == containers.count
            ? "\(running) running" : "\(running)/\(containers.count) running"
        return StatusBarContent(
            text: text, icon: "shippingbox", tint: running > 0 ? .success : nil,
            accessibilityLabel: "Docker: \(running) of \(containers.count) containers running")
    }

    // MARK: - Sidebar Tab (multi-section)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }

        if let error = DockerService.shared.connectionError {
            let errorSection = SidebarSection(
                id: "docker",
                name: "Docker",
                icon: "shippingbox",
                content: AnyView(
                    DockerConnectionErrorView(
                        error: error,
                        theme: AppSettings.shared.theme,
                        fontScale: context.fontScale)),
                prefersOuterScrollView: false,
                // The view renders the error text, so that text is the content identity.
                generation: SidebarSection.generation(for: ["error", error]))
            return SidebarTab(
                id: SidebarTabID(manifest.id),
                icon: manifest.icon, label: manifest.name,
                sections: [errorSection])
        }

        let act = actions
        let theme = AppSettings.shared.theme
        let density = context.density
        let fontScale = context.fontScale

        // Containers section
        let runningCount = DockerService.shared.containers.filter { $0.state == .running }.count
        let totalCount = DockerService.shared.containers.count
        let containerTitle =
            totalCount == 0
            ? "Containers"
            : runningCount == totalCount
                ? "Containers (\(totalCount))"
                : "Containers (\(runningCount)/\(totalCount))"

        let workspaceFolder = WindowManager.shared.activeController?.activeWorkspace?.folderPath
        let pinnedFolder = workspaceFolder.flatMap { ComposeGrouping.hasComposeFile(in: $0) ? $0 : nil }

        let containersSection = SidebarSection(
            id: "docker",
            name: containerTitle,
            icon: "shippingbox",
            content: AnyView(
                DockerContainersView(
                    theme: theme, fontScale: fontScale, density: density,
                    pinnedFolder: pinnedFolder,
                    onComposeLogs: { project in
                        act?.handle(
                            DSLAction(
                                type: "exec", path: nil,
                                command: project.shellCommand("logs --tail 100 -f") + "\r", text: nil))
                    },
                    onExec: { c in
                        act?.handle(
                            DSLAction(
                                type: "exec", path: nil,
                                command: DockerService.shared.execCommand(for: c), text: nil))
                    },
                    onLogs: { c in
                        act?.handle(
                            DSLAction(
                                type: "exec", path: nil,
                                command: "docker logs --tail 100 -f \(c.name)\r", text: nil))
                    },
                    onStart: { c in DockerService.shared.startContainer(c.id) },
                    onStop: { c in DockerService.shared.stopContainer(c.id) },
                    onRestart: { c in DockerService.shared.restartContainer(c.id) },
                    onPause: { c in DockerService.shared.pauseContainer(c.id) },
                    onUnpause: { c in DockerService.shared.unpauseContainer(c.id) },
                    onRemove: { c in DockerService.shared.removeContainer(c.id) },
                    onCopyID: { c in
                        copyToClipboard(c.id)
                    },
                    onInspect: { c in
                        act?.handle(
                            DSLAction(
                                type: "exec", path: nil,
                                command: "docker inspect \(c.name) | less\r", text: nil))
                    }
                )),
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(
                for: [pinnedFolder ?? ""]
                    + DockerService.shared.containers.map {
                        "\($0.id)|\($0.state.rawValue)|\($0.status)|\($0.composeProject ?? "")"
                    }))

        // Images section
        let imagesSection = SidebarSection(
            id: "docker.images",
            name:
                DockerService.shared.images.isEmpty
                ? "Images" : "Images (\(DockerService.shared.images.count))",
            icon: "square.stack",
            content: AnyView(
                DockerImagesView(
                    theme: theme, fontScale: fontScale, density: density,
                    onRemove: { i in DockerService.shared.removeImage(i.id) })),
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(
                for: DockerService.shared.images.map { "\($0.id)|\($0.repoTag)" }))

        // Networks section
        let networksSection = SidebarSection(
            id: "docker.networks",
            name:
                DockerService.shared.networks.isEmpty
                ? "Networks" : "Networks (\(DockerService.shared.networks.count))",
            icon: "network",
            content: AnyView(
                DockerNetworksView(
                    theme: theme, fontScale: fontScale, density: density,
                    onRemove: { n in DockerService.shared.removeNetwork(n.id) })),
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(
                for: DockerService.shared.networks.map { "\($0.id)|\($0.name)" }))

        // Volumes section
        let volumesSection = SidebarSection(
            id: "docker.volumes",
            name:
                DockerService.shared.volumes.isEmpty
                ? "Volumes" : "Volumes (\(DockerService.shared.volumes.count))",
            icon: "cylinder",
            content: AnyView(
                DockerVolumesView(
                    theme: theme, fontScale: fontScale, density: density,
                    onRemove: { v in DockerService.shared.removeVolume(v.name) })),
            prefersOuterScrollView: true,
            generation: SidebarSection.generation(
                for: DockerService.shared.volumes.map { "\($0.name)|\($0.driver)" }))

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon, label: manifest.name,
            sections: [containersSection, imagesSection, networksSection, volumesSection])
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }
}

// MARK: - Connection Error View

private struct DockerConnectionErrorView: View {
    let error: String
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Docker Disconnected")
                .font(fontScale.font(.base).weight(.medium))
                .foregroundStyle(t.text)
            Text(error)
                .font(fontScale.font(.base))
                .foregroundStyle(t.muted)
                .multilineTextAlignment(.center)
            Text("Set the socket path in Settings > Plugins > Docker")
                .font(fontScale.font(.base))
                .foregroundStyle(t.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}
