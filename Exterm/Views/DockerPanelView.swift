import SwiftUI

struct DockerPanelView: View {
    @ObservedObject var settings = SettingsObserver()
    @State private var containers: [DockerService.Container] = []
    @State private var isRefreshing = false

    var onExecIntoContainer: ((DockerService.Container) -> Void)?
    /// Optional SSH host for remote Docker.
    var remoteHost: String?

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let mutedColor = Color(nsColor: theme.chromeMuted)
        let textColor = Color(nsColor: theme.chromeText)
        let accentColor = Color(nsColor: theme.accentColor)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10))
                    .foregroundColor(accentColor)
                Text("CONTAINERS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(mutedColor)
                    .tracking(0.8)

                Spacer()

                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }

                Button(action: { refreshContainers() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(mutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let host = remoteHost {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                        .foregroundColor(mutedColor.opacity(0.6))
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(mutedColor.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            if containers.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 24))
                        .foregroundColor(mutedColor.opacity(0.3))
                    Text("No containers found")
                        .font(.system(size: 11))
                        .foregroundColor(mutedColor.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(containers) { container in
                            ContainerRow(
                                container: container,
                                textColor: textColor,
                                mutedColor: mutedColor,
                                accentColor: accentColor,
                                onExec: { onExecIntoContainer?(container) },
                                onStart: { startContainer(container) },
                                onStop: { stopContainer(container) },
                                onRestart: { restartContainer(container) },
                                onRemove: { removeContainer(container) },
                                remoteHost: remoteHost
                            )
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear { refreshContainers() }
    }

    private func refreshContainers() {
        isRefreshing = true
        if let host = remoteHost {
            DockerService.remoteContainers(host: host) { result in
                containers = result
                isRefreshing = false
            }
        } else {
            DockerService.shared.refresh()
            // Small delay to let refresh complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                containers = DockerService.shared.containers
                isRefreshing = false
            }
        }
    }

    private func startContainer(_ c: DockerService.Container) {
        if let host = remoteHost {
            DockerService.remoteDockerCommand(host: host, args: ["start", c.id]) { refreshContainers() }
        } else {
            DockerService.shared.startContainer(c.id) { refreshContainers() }
        }
    }

    private func stopContainer(_ c: DockerService.Container) {
        if let host = remoteHost {
            DockerService.remoteDockerCommand(host: host, args: ["stop", c.id]) { refreshContainers() }
        } else {
            DockerService.shared.stopContainer(c.id) { refreshContainers() }
        }
    }

    private func restartContainer(_ c: DockerService.Container) {
        if let host = remoteHost {
            DockerService.remoteDockerCommand(host: host, args: ["restart", c.id]) { refreshContainers() }
        } else {
            DockerService.shared.restartContainer(c.id) { refreshContainers() }
        }
    }

    private func removeContainer(_ c: DockerService.Container) {
        if let host = remoteHost {
            DockerService.remoteDockerCommand(host: host, args: ["rm", c.id]) { refreshContainers() }
        } else {
            DockerService.shared.removeContainer(c.id) { refreshContainers() }
        }
    }
}

struct ContainerRow: View {
    let container: DockerService.Container
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onExec: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void
    let remoteHost: String?
    @State private var isHovered = false

    private var stateColor: Color {
        switch container.state {
        case .running: return .green
        case .paused: return .yellow
        case .exited, .dead: return .red
        default: return mutedColor
        }
    }

    private var stateIcon: String {
        switch container.state {
        case .running: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .exited, .dead: return "stop.circle.fill"
        case .restarting: return "arrow.clockwise.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // State indicator
            Image(systemName: stateIcon)
                .font(.system(size: 8))
                .foregroundColor(stateColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Text(container.image)
                    .font(.system(size: 9))
                    .foregroundColor(mutedColor.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Text(container.state.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(stateColor.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? mutedColor.opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if container.state == .running {
                Button("Exec into container") { onExec() }
                Divider()
                Button("Stop") { onStop() }
                Button("Restart") { onRestart() }
            } else {
                Button("Start") { onStart() }
                Divider()
                Button("Remove") { onRemove() }
            }
        }
        .onTapGesture(count: 2) {
            if container.state == .running { onExec() }
        }
    }
}
