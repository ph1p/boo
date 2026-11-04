import SwiftUI

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

// MARK: - Container Row

struct ComposeProjectHeader: View {
    let project: ComposeProject
    let density: SidebarDensity
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale
    let isBusy: Bool
    let canRun: Bool
    let onAction: (ComposeProject.Action) -> Void
    let onLogs: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.isPinned ? "pin.fill" : "square.stack.3d.up")
                .font(.system(size: fontScale.size(.base) - 3))
                .foregroundStyle(
                    project.runningCount > 0 ? t.success : t.textSecondary
                )
                .frame(width: 14)
            Text(project.displayName)
                .font(fontScale.font(.base).weight(.semibold))
                .foregroundStyle(t.text)
                .lineLimit(1)
            if !project.containers.isEmpty {
                Text("\(project.runningCount)/\(project.containers.count)")
                    .font(fontScale.font(.sm, design: .monospaced))
                    .foregroundStyle(t.textSecondary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.mini)
            } else if isHovered && canRun {
                if project.runningCount < project.containers.count || project.containers.isEmpty {
                    iconButton("play.fill", help: "Up (docker compose up -d)") { onAction(.up) }
                }
                if !project.containers.isEmpty {
                    iconButton("arrow.clockwise", help: "Restart") { onAction(.restart) }
                    iconButton("stop.fill", help: "Down (removes containers)") { onAction(.down) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: density == .comfortable ? 26 : 22)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(canRun ? (project.workingDir ?? project.displayName) : "docker CLI not found")
        .contextMenu {
            Button("Up") { onAction(.up) }.disabled(!canRun)
            if !project.containers.isEmpty {
                Button("Restart") { onAction(.restart) }.disabled(!canRun)
                Button("Stop") { onAction(.stop) }.disabled(!canRun)
                Button("Down…") { onAction(.down) }.disabled(!canRun)
                Divider()
                Button("Follow Logs") { onLogs() }
            }
            if let dir = project.workingDir {
                Divider()
                Button("Copy Project Folder") {
                    copyToClipboard(dir)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Compose project \(project.displayName), \(project.runningCount) of \(project.containers.count) running")
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        SidebarIconButton(
            systemName: icon, help: help, tint: t.textSecondary, size: fontScale.size(.base) - 3,
            frame: 20,
            action: action)
    }
}

struct DockerContainerRow: View {
    let container: DockerService.Container
    let density: SidebarDensity
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
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
        case .running: return t.success
        case .paused, .restarting: return t.warning
        case .exited, .dead: return t.error
        default: return t.muted
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
                .foregroundStyle(stateColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    let imageName =
                        container.image.hasPrefix("sha256:")
                        ? String(container.image.prefix(19)) : container.image
                    Text(imageName)
                        .font(fontScale.font(.sm))
                        .foregroundStyle(t.textSecondary)
                        .lineLimit(1)
                    if !container.ports.isEmpty {
                        Text(container.ports)
                            .font(fontScale.font(.sm, design: .monospaced))
                            .foregroundStyle(t.textTertiary)
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
                        // Deliberate raw alpha: dimmed status hue, no token per status color.
                        .foregroundStyle(stateColor.opacity(0.7))
                } else if container.state != .running {
                    Text(container.state.rawValue)
                        .font(fontScale.font(.sm, design: .monospaced))
                        // Deliberate raw alpha: dimmed status hue, no token per status color.
                        .foregroundStyle(stateColor.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? t.hoverFill : Color.clear)
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

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        SidebarIconButton(
            systemName: icon, help: help, tint: t.textSecondary,
            size: fontScale.size(.base) - 2, frame: 22, action: action)
    }
}

// MARK: - Image Row

struct DockerImageRow: View {
    let image: DockerService.DockerImage
    let density: SidebarDensity
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundStyle(t.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(image.repoTag)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(image.id)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundStyle(t.textTertiary)
                    if let age = relativeUptime(from: image.createdAt) {
                        Text(age)
                            .font(fontScale.font(.sm))
                            .foregroundStyle(t.textTertiary)
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundStyle(t.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove image")
            } else {
                Text(formatBytes(image.size))
                    .font(fontScale.font(.sm, design: .monospaced))
                    .foregroundStyle(t.textTertiary)
            }
        }
        .frame(minHeight: itemHeight)
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? t.hoverFill : Color.clear)
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

struct DockerNetworkRow: View {
    let network: DockerService.DockerNetwork
    let density: SidebarDensity
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundStyle(t.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(network.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(network.driver)
                        .font(fontScale.font(.sm))
                        .foregroundStyle(t.textSecondary)
                    Text(network.scope)
                        .font(fontScale.font(.sm))
                        .foregroundStyle(t.textTertiary)
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundStyle(t.textSecondary)
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
                .fill(isHovered ? t.hoverFill : Color.clear)
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

struct DockerVolumeRow: View {
    let volume: DockerService.DockerVolume
    let density: SidebarDensity
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale
    let onRemove: () -> Void
    @State private var isHovered = false

    private var itemHeight: CGFloat { density == .comfortable ? 28 : 22 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder")
                .font(.system(size: fontScale.size(.base) - 2))
                .foregroundStyle(t.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(t.text)
                    .lineLimit(1)

                Text(volume.driver)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.textSecondary)
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: fontScale.size(.base) - 2))
                        .foregroundStyle(t.textSecondary)
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
                .fill(isHovered ? t.hoverFill : Color.clear)
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
