import SwiftUI

// MARK: - Containers Section View

struct DockerContainersView: View {
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let density: SidebarDensity
    /// Workspace folder holding a compose file; its project is listed first.
    var pinnedFolder: String?
    var onComposeLogs: ((ComposeProject) -> Void)?
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
    @State private var downTarget: ComposeProject?
    @State private var busyProjects: Set<String> = []

    private static func isUp(_ c: DockerService.Container) -> Bool {
        c.state == .running || c.state == .paused || c.state == .restarting
    }

    var body: some View {
        let groups = ComposeGrouping.group(service.containers, pinnedFolder: pinnedFolder)
        let running = groups.loose.filter(Self.isUp)
        let stopped = groups.loose.filter { !Self.isUp($0) }
        VStack(alignment: .leading, spacing: 0) {
            if service.containers.isEmpty && groups.projects.isEmpty {
                DockerEmptyView(icon: "shippingbox", label: "No containers", theme: theme, fontScale: fontScale)
            } else {
                ForEach(groups.projects) { project in
                    ComposeProjectHeader(
                        project: project, density: density, theme: theme, fontScale: fontScale,
                        isBusy: busyProjects.contains(project.id),
                        canRun: service.dockerPath != nil,
                        onAction: { action in
                            if action == .down {
                                downTarget = project
                            } else {
                                run(action, project)
                            }
                        },
                        onLogs: { onComposeLogs?(project) })
                    ForEach(project.containers, id: \.id) { c in
                        row(c).padding(.leading, 10)
                    }
                }
                if !groups.projects.isEmpty && !groups.loose.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                ForEach(running, id: \.id) { c in row(c) }
                if !running.isEmpty && !stopped.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                ForEach(stopped, id: \.id) { c in row(c) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .destructiveConfirmation(
            "Remove container \"\(deleteTarget?.name ?? "")\"?", item: $deleteTarget,
            message: "This will permanently delete the container."
        ) { onRemove?($0) }
        .destructiveConfirmation(
            "Take down \"\(downTarget?.displayName ?? "")\"?", item: $downTarget, button: "Down",
            message: "Stops and removes the project's containers and networks. Volumes are kept."
        ) { run(.down, $0) }
    }

    private func run(_ action: ComposeProject.Action, _ project: ComposeProject) {
        busyProjects.insert(project.id)
        DockerService.shared.composeAction(action, project: project) { error in
            busyProjects.remove(project.id)
            if let error { BooAlert.showTransient("compose \(action.rawValue): \(error)") }
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
        .destructiveConfirmation(
            "Remove image \"\(deleteTarget?.repoTag ?? "")\"?", item: $deleteTarget,
            message: "This will permanently delete the image."
        ) { onRemove?($0) }
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
        .destructiveConfirmation(
            "Remove network \"\(deleteTarget?.name ?? "")\"?", item: $deleteTarget,
            message: "This will permanently delete the network."
        ) { onRemove?($0) }
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
        .destructiveConfirmation(
            "Remove volume \"\(deleteTarget?.name ?? "")\"?", item: $deleteTarget,
            message: "This will permanently delete the volume and all its data."
        ) { onRemove?($0) }
    }
}

// MARK: - Empty State

private struct DockerEmptyView: View {
    let icon: String
    let label: String
    let theme: TerminalTheme
    private var t: Tokens { Tokens(theme: theme) }
    let fontScale: SidebarFontScale

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(fontScale.font(.base))
                .foregroundStyle(t.textTertiary)
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

extension View {
    /// Destructive confirmation alert shown while `item` is non-nil; clears it on dismiss.
    fileprivate func destructiveConfirmation<Item>(
        _ title: String, item: Binding<Item?>, button: String = "Remove", message: String,
        perform: @escaping (Item) -> Void
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } })
        ) {
            Button(button, role: .destructive) {
                if let value = item.wrappedValue { perform(value) }
                item.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { item.wrappedValue = nil }
        } message: {
            Text(message)
        }
    }
}
