import SwiftUI

@MainActor
private func copyToClipboard(_ text: String) {
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
    private var isActivated = false

    init() {
        DockerService.shared.onContainersChanged = { [weak self] _ in
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
                if self?.isActivated == true {
                    DockerService.shared.stopWatching()
                    DockerService.shared.startWatching()
                }
                self?.onRequestCycleRerun?()
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        DockerService.shared.stopWatching()
    }

    // MARK: - Activation Lifecycle

    func pluginDidActivate() {
        isActivated = true
        applySocketPathSetting()
        DockerService.shared.startWatching()
    }

    func pluginDidDeactivate() {
        isActivated = false
        DockerService.shared.stopWatching()
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
                generation: 0)
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

        let containersSection = SidebarSection(
            id: "docker",
            name: containerTitle,
            icon: "shippingbox",
            content: AnyView(
                DockerContainersView(
                    theme: theme, fontScale: fontScale, density: density,
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
            generation: UInt64(DockerService.shared.containers.count))

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
            generation: UInt64(DockerService.shared.images.count))

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
            generation: UInt64(DockerService.shared.networks.count))

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
            generation: UInt64(DockerService.shared.volumes.count))

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
    let fontScale: SidebarFontScale

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text("Docker Disconnected")
                .font(fontScale.font(.base).weight(.medium))
                .foregroundColor(Color(nsColor: theme.chromeText))
            Text(error)
                .font(fontScale.font(.base))
                .foregroundColor(Color(nsColor: theme.chromeMuted))
                .multilineTextAlignment(.center)
            Text("Set the socket path in Settings > Plugins > Docker")
                .font(fontScale.font(.base))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Uptime / size helpers

private func relativeUptime(from date: Date?) -> String? {
    guard let date = date else { return nil }
    let elapsed = -date.timeIntervalSinceNow
    guard elapsed >= 0 else { return nil }
    if elapsed < 60 { return "\(Int(elapsed))s" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
    if elapsed < 86400 { return "\(Int(elapsed / 3600))h" }
    return "\(Int(elapsed / 86400))d"
}

private func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb < 1000 { return String(format: "%.0f MB", mb) }
    return String(format: "%.1f GB", mb / 1024)
}

// MARK: - Containers Section View

struct DockerContainersView: View {
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let density: SidebarDensity
    var onExec: ((DockerService.Container) -> Void)?
    var onLogs: ((DockerService.Container) -> Void)?
    var onStart: ((DockerService.Container) -> Void)?
    var onStop: ((DockerService.Container) -> Void)?
    var onRestart: ((DockerService.Container) -> Void)?
    var onPause: ((DockerService.Container) -> Void)?
    var onUnpause: ((DockerService.Container) -> Void)?
    var onRemove: ((DockerService.Container) -> Void)?
    var onCopyID: ((DockerService.Container) -> Void)?
    var onInspect: ((DockerService.Container) -> Void)?

    @ObservedObject private var service = DockerService.shared
    @State private var deleteTarget: DockerService.Container?

    private var running: [DockerService.Container] {
        service.containers.filter {
            $0.state == .running || $0.state == .paused || $0.state == .restarting
        }
    }
    private var stopped: [DockerService.Container] {
        service.containers.filter {
            $0.state == .exited || $0.state == .dead
                || $0.state == .created || $0.state == .unknown
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.containers.isEmpty {
                DockerEmptyView(icon: "shippingbox", label: "No containers", theme: theme, fontScale: fontScale)
            } else {
                ForEach(running, id: \.id) { c in row(c) }
                if !running.isEmpty && !stopped.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                ForEach(stopped, id: \.id) { c in row(c) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert(
            "Remove container \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let c = deleteTarget { onRemove?(c) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently delete the container.")
        }
    }

    @ViewBuilder
    private func row(_ c: DockerService.Container) -> some View {
        DockerContainerRow(
            container: c, density: density, theme: theme, fontScale: fontScale,
            onExec: { onExec?(c) },
            onLogs: { onLogs?(c) },
            onStart: { onStart?(c) },
            onStop: { onStop?(c) },
            onRestart: { onRestart?(c) },
            onPause: { onPause?(c) },
            onUnpause: { onUnpause?(c) },
            onRemove: { deleteTarget = c },
            onCopyID: { onCopyID?(c) },
            onInspect: { onInspect?(c) }
        )
    }
}

// MARK: - Images Section View

struct DockerImagesView: View {
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let density: SidebarDensity
    var onRemove: ((DockerService.DockerImage) -> Void)?

    @ObservedObject private var service = DockerService.shared
    @State private var deleteTarget: DockerService.DockerImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.images.isEmpty {
                DockerEmptyView(icon: "square.stack", label: "No images", theme: theme, fontScale: fontScale)
            } else {
                ForEach(service.images) { image in
                    DockerImageRow(
                        image: image, density: density, theme: theme, fontScale: fontScale,
                        onRemove: { deleteTarget = image })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert(
            "Remove image \"\(deleteTarget?.repoTag ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let i = deleteTarget { onRemove?(i) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently delete the image.")
        }
    }
}

// MARK: - Networks Section View

struct DockerNetworksView: View {
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let density: SidebarDensity
    var onRemove: ((DockerService.DockerNetwork) -> Void)?

    @ObservedObject private var service = DockerService.shared
    @State private var deleteTarget: DockerService.DockerNetwork?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.networks.isEmpty {
                DockerEmptyView(icon: "network", label: "No networks", theme: theme, fontScale: fontScale)
            } else {
                ForEach(service.networks) { network in
                    DockerNetworkRow(
                        network: network, density: density, theme: theme, fontScale: fontScale,
                        onRemove: { deleteTarget = network })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert(
            "Remove network \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let n = deleteTarget { onRemove?(n) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently delete the network.")
        }
    }
}

// MARK: - Volumes Section View

struct DockerVolumesView: View {
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let density: SidebarDensity
    var onRemove: ((DockerService.DockerVolume) -> Void)?

    @ObservedObject private var service = DockerService.shared
    @State private var deleteTarget: DockerService.DockerVolume?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.volumes.isEmpty {
                DockerEmptyView(icon: "cylinder", label: "No volumes", theme: theme, fontScale: fontScale)
            } else {
                ForEach(service.volumes) { volume in
                    DockerVolumeRow(
                        volume: volume, density: density, theme: theme, fontScale: fontScale,
                        onRemove: { deleteTarget = volume })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert(
            "Remove volume \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let v = deleteTarget { onRemove?(v) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently delete the volume and all its data.")
        }
    }
}

// MARK: - Empty State

private struct DockerEmptyView: View {
    let icon: String
    let label: String
    let theme: TerminalTheme
    let fontScale: SidebarFontScale

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(fontScale.font(.base))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Container Row

private struct DockerContainerRow: View {
    let container: DockerService.Container
    let density: SidebarDensity
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let onExec: () -> Void
    let onLogs: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onPause: () -> Void
    let onUnpause: () -> Void
    let onRemove: () -> Void
    let onCopyID: () -> Void
    let onInspect: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    private var stateColor: Color {
        switch container.state {
        case .running: return .green
        case .paused: return .yellow
        case .exited, .dead: return .red
        case .restarting: return .orange
        default: return Color(nsColor: theme.chromeMuted)
        }
    }

    private var stateIcon: String {
        switch container.state {
        case .running: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .exited, .dead: return "stop.circle.fill"
        case .restarting: return "arrow.clockwise.circle.fill"
        case .created: return "circle.dashed"
        default: return "questionmark.circle"
        }
    }

    private var firstPublicPort: Int? {
        for part in container.ports.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let arrow = part.range(of: "->") {
                let hostPart = String(part[part.startIndex..<arrow.lowerBound])
                let portStr = hostPart.split(separator: ":").last.map(String.init) ?? hostPart
                if let port = Int(portStr), port > 0 { return port }
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: stateIcon)
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundColor(stateColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    let imageName =
                        container.image.hasPrefix("sha256:")
                        ? String(container.image.prefix(19)) : container.image
                    Text(imageName)
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                        .lineLimit(1)
                    if !container.ports.isEmpty {
                        Text(container.ports)
                            .font(fontScale.font(.sm, design: .monospaced))
                            .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if isHovered {
                hoverActions
            } else {
                if container.state == .running,
                    let uptime = relativeUptime(from: container.createdAt)
                {
                    Text(uptime)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(stateColor.opacity(0.7))
                } else if container.state != .running {
                    Text(container.state.rawValue)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(stateColor.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if container.state == .running {
                onExec()
            } else if container.state == .exited || container.state == .created {
                onStart()
            }
        }
        .contextMenu {
            if container.state == .running {
                Button("Exec into container") { onExec() }
                Button("View logs") { onLogs() }
                Button("Inspect") { onInspect() }
                if let port = firstPublicPort {
                    Button("Open in Browser (:\(port))") {
                        if let url = URL(string: "http://localhost:\(port)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Divider()
                Button("Pause") { onPause() }
                Button("Stop") { onStop() }
                Button("Restart") { onRestart() }
            } else if container.state == .paused {
                Button("View logs") { onLogs() }
                Button("Inspect") { onInspect() }
                Divider()
                Button("Unpause") { onUnpause() }
                Button("Stop") { onStop() }
                Button("Restart") { onRestart() }
            } else {
                Button("Inspect") { onInspect() }
                Divider()
                Button("Start") { onStart() }
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            }
            Divider()
            Button("Copy Container ID") { onCopyID() }
            Button("Copy Name") {
                copyToClipboard(container.name)
            }
            if !container.ports.isEmpty {
                Button("Copy Ports") {
                    copyToClipboard(container.ports)
                }
            }
        }
        .accessibilityLabel("\(container.name), \(container.state.rawValue), \(container.image)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 2) {
            switch container.state {
            case .running:
                iconButton("doc.text", help: "View logs", action: onLogs)
                iconButton("terminal", help: "Exec into container", action: onExec)
                iconButton("stop.fill", help: "Stop", action: onStop)
            case .paused:
                iconButton("doc.text", help: "View logs", action: onLogs)
                iconButton("play.fill", help: "Unpause", action: onUnpause)
                iconButton("stop.fill", help: "Stop", action: onStop)
            case .exited, .dead, .created:
                iconButton("play.fill", help: "Start", action: onStart)
                iconButton("trash", help: "Remove", action: onRemove)
            case .restarting:
                iconButton("doc.text", help: "View logs", action: onLogs)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Image Row

private struct DockerImageRow: View {
    let image: DockerService.DockerImage
    let density: SidebarDensity
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(image.repoTag)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(image.id)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                    if let age = relativeUptime(from: image.createdAt) {
                        Text(age)
                            .font(fontScale.font(.sm))
                            .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.4))
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove image")
            } else {
                Text(formatBytes(image.size))
                    .font(fontScale.font(.sm, design: .monospaced))
                    .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.4))
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy ID") {
                copyToClipboard(image.id)
            }
            Button("Copy Tag") {
                copyToClipboard(image.repoTag)
            }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - Network Row

private struct DockerNetworkRow: View {
    let network: DockerService.DockerNetwork
    let density: SidebarDensity
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(network.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(network.driver)
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
                    Text(network.scope)
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.4))
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove network")
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy ID") {
                copyToClipboard(network.id)
            }
            Button("Copy Name") {
                copyToClipboard(network.name)
            }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - Volume Row

private struct DockerVolumeRow: View {
    let volume: DockerService.DockerVolume
    let density: SidebarDensity
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)

                Text(volume.driver)
                    .font(fontScale.font(.sm))
                    .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove volume")
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Name") {
                copyToClipboard(volume.name)
            }
            Button("Copy Mountpoint") {
                copyToClipboard(volume.mountpoint)
            }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }
}
