import SwiftUI

/// Built-in Docker plugin. Shows running containers when Docker is available.
/// Available locally (not in remote sessions).
@MainActor
final class DockerPluginNew: ExtermPluginProtocol {
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    init() {
        DockerService.shared.startWatching()
        DockerService.shared.onContainersChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.onRequestCycleRerun?()
            }
        }
    }

    let manifest = PluginManifest(
        id: "docker",
        name: "Docker",
        version: "1.0.0",
        icon: "shippingbox",
        description: "Running Docker containers",
        when: "!remote",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(sidebarPanel: true, statusBarSegment: true),
        statusBar: PluginManifest.StatusBarManifest(position: "right", priority: 10, template: nil),
        settings: nil
    )

    // MARK: - Section Title

    func sectionTitle(context: TerminalContext) -> String? {
        let containers = DockerService.shared.containers
        guard !containers.isEmpty else { return nil }
        let running = containers.filter { $0.state == .running }.count
        return "Docker (\(running)/\(containers.count))"
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent? {
        let containers = DockerService.shared.containers
        guard !containers.isEmpty else { return nil }
        let running = containers.filter { $0.state == .running }.count
        let text =
            running == containers.count
            ? "\(running) running"
            : "\(running)/\(containers.count) running"
        return StatusBarContent(
            text: text,
            icon: "shippingbox",
            tint: running > 0 ? .success : nil,
            accessibilityLabel: "Docker: \(running) of \(containers.count) containers running"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView? {
        let containers = DockerService.shared.containers
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity

        return AnyView(
            DockerPluginDetailView(
                containers: containers,
                density: density,
                theme: theme,
                onExec: { container in
                    actionHandler.handle(
                        DSLAction(
                            type: "exec", path: nil, command: DockerService.shared.execCommand(for: container),
                            text: nil))
                },
                onLogs: { container in
                    let cmd = "docker logs --tail 100 -f \(container.name)\r"
                    actionHandler.handle(DSLAction(type: "exec", path: nil, command: cmd, text: nil))
                },
                onStart: { container in
                    DockerService.shared.startContainer(container.id) { DockerService.shared.refresh() }
                },
                onStop: { container in
                    DockerService.shared.stopContainer(container.id) { DockerService.shared.refresh() }
                },
                onRestart: { container in
                    DockerService.shared.restartContainer(container.id) { DockerService.shared.refresh() }
                },
                onPause: { container in
                    DockerService.shared.pauseContainer(container.id) { DockerService.shared.refresh() }
                },
                onUnpause: { container in
                    DockerService.shared.unpauseContainer(container.id) { DockerService.shared.refresh() }
                },
                onRemove: { container in
                    DockerService.shared.removeContainer(container.id) { DockerService.shared.refresh() }
                },
                onCopyID: { container in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.id, forType: .string)
                },
                onInspect: { container in
                    let cmd = "docker inspect \(container.name) | less\r"
                    actionHandler.handle(DSLAction(type: "exec", path: nil, command: cmd, text: nil))
                }
            ))
    }
}

// MARK: - Detail View

struct DockerPluginDetailView: View {
    let containers: [DockerService.Container]
    let density: SidebarDensity
    let theme: TerminalTheme
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

    private var runningContainers: [DockerService.Container] {
        containers.filter { $0.state == .running || $0.state == .paused || $0.state == .restarting }
    }

    private var stoppedContainers: [DockerService.Container] {
        containers.filter { $0.state == .exited || $0.state == .dead || $0.state == .created || $0.state == .unknown }
    }

    var body: some View {
        let itemHeight: CGFloat = density == .comfortable ? 26 : 20

        VStack(alignment: .leading, spacing: 0) {
            if containers.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 24))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.3))
                    Text("No containers found")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Running containers
                if !runningContainers.isEmpty {
                    DockerGroupHeader(title: "Running", count: runningContainers.count, theme: theme, density: density)
                    ForEach(runningContainers, id: \.id) { container in
                        containerRow(container, itemHeight: itemHeight)
                    }
                }

                // Stopped containers
                if !stoppedContainers.isEmpty {
                    DockerGroupHeader(title: "Stopped", count: stoppedContainers.count, theme: theme, density: density)
                    ForEach(stoppedContainers, id: \.id) { container in
                        containerRow(container, itemHeight: itemHeight)
                    }
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func containerRow(_ container: DockerService.Container, itemHeight: CGFloat) -> some View {
        DockerContainerRow(
            container: container,
            density: density,
            theme: theme,
            itemHeight: itemHeight,
            onExec: { onExec?(container) },
            onLogs: { onLogs?(container) },
            onStart: { onStart?(container) },
            onStop: { onStop?(container) },
            onRestart: { onRestart?(container) },
            onPause: { onPause?(container) },
            onUnpause: { onUnpause?(container) },
            onRemove: { onRemove?(container) },
            onCopyID: { onCopyID?(container) },
            onInspect: { onInspect?(container) }
        )
    }
}

// MARK: - Group Header

private struct DockerGroupHeader: View {
    let title: String
    let count: Int
    let theme: TerminalTheme
    let density: SidebarDensity

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.4))
            Spacer()
        }
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

}

// MARK: - Container Row

private struct DockerContainerRow: View {
    let container: DockerService.Container
    let density: SidebarDensity
    let theme: TerminalTheme
    let itemHeight: CGFloat
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: stateIcon)
                .font(.system(size: 8))
                .foregroundColor(stateColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(.system(size: density == .comfortable ? 12 : 11, weight: .medium))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(container.image)
                        .font(.system(size: density == .comfortable ? 10 : 9))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                        .lineLimit(1)

                    if !container.ports.isEmpty {
                        Text(container.ports)
                            .font(.system(size: density == .comfortable ? 10 : 9, design: .monospaced))
                            .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Inline action buttons on hover
            if isHovered && container.state == .running {
                Button(action: onLogs) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("View logs")

                Button(action: onExec) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Exec into container")
            } else if !isHovered {
                Text(container.status)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(stateColor.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: theme.chromeMuted).opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if container.state == .running { onExec() }
        }
        .contextMenu {
            if container.state == .running {
                Button("Exec into container") { onExec() }
                Button("View logs") { onLogs() }
                Button("Inspect") { onInspect() }
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
                Button("Remove") { onRemove() }
            }
            Divider()
            Button("Copy Container ID") { onCopyID() }
            if !container.ports.isEmpty {
                Button("Copy Ports") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.ports, forType: .string)
                }
            }
        }
        .accessibilityLabel("\(container.name), \(container.state.rawValue), \(container.image)")
        .accessibilityAddTraits(.isButton)
    }

}
