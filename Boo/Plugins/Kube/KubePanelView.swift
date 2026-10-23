import SwiftUI

struct KubePanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    @ObservedObject var store = KubeStore.shared
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var filter = ""

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let colors = KubeRowColors(
            text: Color(nsColor: theme.chromeText),
            muted: Color(nsColor: theme.chromeMuted),
            accent: Color(nsColor: theme.accentColor))
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let pods = store.pods.items.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        let deployments = store.deployments.items.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        let services = store.services.items.filter { query.isEmpty || $0.name.lowercased().contains(query) }

        VStack(alignment: .leading, spacing: 0) {
            header(colors: colors, guarded: store.isGuardedContext(store.context))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.muted)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(colors.text)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if let error = store.error {
                Text(error)
                    .font(fontScale.font(.xs))
                    .foregroundStyle(Color(nsColor: .systemRed).opacity(0.85))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if store.kubectlPath == nil || store.context == nil {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "helm")
                        .font(.system(size: 24))
                        .foregroundStyle(colors.muted.opacity(0.3))
                    Text(store.kubectlPath == nil ? "kubectl not found" : "No current kube context")
                        .font(fontScale.font(.base))
                        .foregroundStyle(colors.muted.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        sectionTitle("Pods", count: pods.count, colors: colors)
                        ForEach(pods) { KubePodRow(pod: $0, fontScale: fontScale, colors: colors) }
                        sectionTitle("Deployments", count: deployments.count, colors: colors)
                        ForEach(deployments) { KubeDeploymentRow(deployment: $0, fontScale: fontScale, colors: colors) }
                        sectionTitle("Services", count: services.count, colors: colors)
                        ForEach(services) { KubeServiceRow(service: $0, fontScale: fontScale, colors: colors) }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear { store.startWatching() }
    }

    private func header(colors: KubeRowColors, guarded: Bool) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(store.config.contextNames, id: \.self) { name in
                    Button {
                        store.useContext(name)
                    } label: {
                        if name == store.context { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text(store.context ?? "no context")
                    .foregroundStyle(guarded ? Color(nsColor: .systemRed) : colors.text)
            }
            .help(guarded ? "A rule switches profile for this context" : "Switch context (kubectl config use-context)")
            Text("/").foregroundStyle(colors.muted)
            Menu {
                ForEach(store.namespaces.isEmpty ? [store.namespace] : store.namespaces, id: \.self) { name in
                    Button {
                        store.useNamespace(name)
                    } label: {
                        if name == store.namespace { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text(store.namespace).foregroundStyle(colors.text)
            }
            .help("Switch namespace of the current context")
            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(fontScale.font(.sm).weight(.medium))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .disabled(store.context == nil)
    }

    private func sectionTitle(_ title: String, count: Int, colors: KubeRowColors) -> some View {
        Text("\(title.uppercased())  \(count)")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(colors.muted.opacity(0.8))
            .tracking(0.6)
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }
}

struct KubeRowColors {
    var text: Color
    var muted: Color
    var accent: Color
}

/// Hover background + layout shared by the rows.
private struct KubeRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(fontScale.font(.xs))
                        .foregroundStyle(colors.muted.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? colors.muted.opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct KubePodRow: View {
    let pod: KubePod
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    private var statusColor: Color {
        switch pod.health {
        case .ok: return Color(nsColor: .systemGreen)
        case .pending: return Color(nsColor: .systemOrange)
        case .failing: return Color(nsColor: .systemRed)
        case .done: return colors.muted.opacity(0.6)
        }
    }

    var body: some View {
        let subtitle =
            "\(pod.status) · \(pod.ready)/\(pod.total)"
            + (pod.restarts > 0 ? " · ↻\(pod.restarts)" : "")
        KubeRow(
            icon: "circle.fill", iconColor: statusColor, title: pod.name, subtitle: subtitle,
            fontScale: fontScale, colors: colors
        ) {
            if let created = pod.createdAt {
                Text(formatCompactAge(created))
                    .font(fontScale.font(.xs).monospacedDigit())
                    .foregroundStyle(colors.muted.opacity(0.6))
            }
        }
        .onTapGesture(count: 2) { store.logs(pod.name) }
        .help("Double-click: follow logs · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Pod \(pod.name), \(pod.status), \(pod.ready) of \(pod.total) ready")
        .contextMenu {
            if pod.containers.count > 1 {
                Menu("Exec Shell") {
                    ForEach(pod.containers, id: \.self) { c in Button(c) { store.exec(pod, container: c) } }
                }
                Menu("Follow Logs") {
                    ForEach(pod.containers, id: \.self) { c in Button(c) { store.logs(pod.name, container: c) } }
                }
            } else {
                Button("Exec Shell") { store.exec(pod, container: nil) }
                Button("Follow Logs") { store.logs(pod.name) }
            }
            if !pod.ports.isEmpty {
                Menu("Port-Forward") {
                    ForEach(pod.ports, id: \.self) { port in
                        Button("localhost:\(KubeCommand.localPort(for: port)) → \(port)") {
                            store.portForward("pod/" + pod.name, port: port)
                        }
                    }
                }
            }
            Button("Describe") { store.describe("pod/" + pod.name) }
            Button("Copy Name") { PluginActions.copyToPasteboard(pod.name) }
            Divider()
            Button("Delete Pod…") { store.deletePod(pod) }
        }
    }
}

private struct KubeDeploymentRow: View {
    let deployment: KubeDeployment
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    var body: some View {
        let healthy = deployment.ready == deployment.replicas
        KubeRow(
            icon: "square.stack.3d.up", iconColor: healthy ? colors.accent : Color(nsColor: .systemOrange),
            title: deployment.name, subtitle: nil, fontScale: fontScale, colors: colors
        ) {
            Text("\(deployment.ready)/\(deployment.replicas)")
                .font(fontScale.font(.xs).monospacedDigit())
                .foregroundStyle(healthy ? colors.muted.opacity(0.7) : Color(nsColor: .systemOrange))
        }
        .onTapGesture(count: 2) { store.logs("deployment/" + deployment.name) }
        .help("Double-click: follow logs · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Deployment \(deployment.name), \(deployment.ready) of \(deployment.replicas) ready")
        .contextMenu {
            Button("Follow Logs") { store.logs("deployment/" + deployment.name) }
            Button("Describe") { store.describe("deployment/" + deployment.name) }
            Button("Copy Name") { PluginActions.copyToPasteboard(deployment.name) }
            Divider()
            Button("Scale…") { store.scale(deployment) }
            Button("Rollout Restart…") { store.rolloutRestart(deployment) }
        }
    }
}

private struct KubeServiceRow: View {
    let service: KubeSvc
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    var body: some View {
        KubeRow(
            icon: "network", iconColor: colors.muted.opacity(0.7), title: service.name,
            subtitle: [service.type, service.clusterIP].compactMap { $0 }.joined(separator: " · "),
            fontScale: fontScale, colors: colors
        ) {
            Text(service.portsLabel)
                .font(fontScale.font(.xs).monospacedDigit())
                .foregroundStyle(colors.muted.opacity(0.7))
                .lineLimit(1)
        }
        .onTapGesture(count: 2) {
            if let port = service.ports.first { store.portForward("svc/" + service.name, port: port.port) }
        }
        .help("Double-click: port-forward the first port · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Service \(service.name), \(service.type), ports \(service.portsLabel)")
        .contextMenu {
            if !service.ports.isEmpty {
                Menu("Port-Forward") {
                    ForEach(service.ports, id: \.port) { p in
                        Button("localhost:\(KubeCommand.localPort(for: p.port)) → \(p.port)") {
                            store.portForward("svc/" + service.name, port: p.port)
                        }
                    }
                }
            }
            Button("Describe") { store.describe("svc/" + service.name) }
            Button("Copy Name") { PluginActions.copyToPasteboard(service.name) }
        }
    }
}
