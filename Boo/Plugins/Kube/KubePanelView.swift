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
                        ForEach(KubeKind.allCases, id: \.self) { kind in
                            section(kind, query: query, colors: colors)
                        }
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
            Button {
                store.showEvents()
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.muted)
            }
            .buttonStyle(.plain)
            .help("Watch events of this namespace in a new tab")
            .accessibilityLabel("Watch events")
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(fontScale.font(.sm).weight(.medium))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .disabled(store.context == nil)
    }

    @ViewBuilder
    private func section(_ kind: KubeKind, query: String, colors: KubeRowColors) -> some View {
        switch kind {
        case .pods:
            kindSection(
                kind, store.pods.items, query: query, colors: colors, fields: { [$0.name, $0.status] },
                failing: { $0.health == .failing }
            ) { KubePodRow(pod: $0, fontScale: fontScale, colors: colors) }
        case .deployments, .statefulsets, .daemonsets:
            let all =
                kind == .deployments
                ? store.deployments.items : kind == .statefulsets ? store.statefulsets.items : store.daemonsets.items
            kindSection(kind, all, query: query, colors: colors, fields: { [$0.name] }, failing: { !$0.healthy }) {
                KubeWorkloadRow(kind: kind, workload: $0, fontScale: fontScale, colors: colors)
            }
        case .jobs:
            kindSection(
                kind, store.jobs.items, query: query, colors: colors, fields: { [$0.name] },
                failing: { $0.health == .failed }
            ) { KubeJobRow(job: $0, fontScale: fontScale, colors: colors) }
        case .cronjobs:
            kindSection(kind, store.cronjobs.items, query: query, colors: colors, fields: { [$0.name] }) {
                KubeCronJobRow(cronJob: $0, fontScale: fontScale, colors: colors)
            }
        case .services:
            kindSection(kind, store.services.items, query: query, colors: colors, fields: { [$0.name, $0.type] }) {
                KubeServiceRow(service: $0, fontScale: fontScale, colors: colors)
            }
        case .ingresses:
            kindSection(kind, store.ingresses.items, query: query, colors: colors, fields: { [$0.name] + $0.hosts }) {
                KubeIngressRow(ingress: $0, fontScale: fontScale, colors: colors)
            }
        }
    }

    /// Title with counts, then the rows when expanded. The filter matches names and
    /// status words ("crash", "pending", "nodeport").
    @ViewBuilder
    private func kindSection<Item: Identifiable, Row: View>(
        _ kind: KubeKind, _ all: [Item], query: String, colors: KubeRowColors,
        fields: (Item) -> [String], failing: (Item) -> Bool = { _ in false },
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        let items =
            query.isEmpty
            ? all : all.filter { fields($0).contains { $0.range(of: query, options: .caseInsensitive) != nil } }
        sectionTitle(kind, count: items.count, failing: items.count(where: failing), colors: colors)
        if store.isExpanded(kind) {
            sectionError(kind)
            ForEach(items, content: row)
        }
    }

    @ViewBuilder
    private func sectionError(_ kind: KubeKind) -> some View {
        if let message = store.errors[kind] {
            Text(message)
                .font(fontScale.font(.xs))
                .foregroundStyle(Color(nsColor: .systemRed).opacity(0.85))
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
        }
    }

    /// Collapsed sections show no count: they aren't watched, so it would be stale.
    private func sectionTitle(_ kind: KubeKind, count: Int, failing: Int, colors: KubeRowColors) -> some View {
        let open = store.isExpanded(kind)
        return Button {
            store.toggle(kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 8)
                Text(kind.title.uppercased())
                if open {
                    Text("\(count)")
                    if failing > 0 {
                        Text("· \(failing) unhealthy").foregroundStyle(Color(nsColor: .systemRed).opacity(0.85))
                    }
                }
                Spacer()
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(colors.muted.opacity(0.8))
            .tracking(0.6)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            open
                ? "Collapse (stops watching \(kind.title.lowercased()))" : "Expand and watch \(kind.title.lowercased())"
        )
        .accessibilityLabel("\(kind.title), \(open ? "expanded, \(count) items" : "collapsed")")
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
            if pod.restarts > 0 {
                if pod.containers.count > 1 {
                    Menu("Previous Logs") {
                        ForEach(pod.containers, id: \.self) { c in
                            Button(c) { store.logs(pod.name, container: c, previous: true) }
                        }
                    }
                } else {
                    Button("Previous Logs") { store.logs(pod.name, previous: true) }
                }
            }
            KubeInspectItems(target: "pod/" + pod.name, name: pod.name)
            Divider()
            Button("Delete Pod…") { store.delete(.pods, name: pod.name, info: "A controller may recreate it.") }
        }
    }
}

/// Describe / YAML / Edit / Copy Name, shared by every row's context menu.
private struct KubeInspectItems: View {
    let target: String
    let name: String
    private var store: KubeStore { .shared }

    var body: some View {
        Button("Describe") { store.describe(target) }
        Button("View YAML") { store.showYAML(target) }
        Button("Edit…") { store.edit(target) }
        Button("Copy Name") { PluginActions.copyToPasteboard(name) }
    }
}

private struct KubeWorkloadRow: View {
    let kind: KubeKind
    let workload: KubeWorkload
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }
    private var target: String { kind.resource + "/" + workload.name }

    private var icon: String {
        switch kind {
        case .statefulsets: "cylinder.split.1x2"
        case .daemonsets: "square.grid.3x1.below.line.grid.1x2"
        default: "square.stack.3d.up"
        }
    }

    var body: some View {
        let healthy = workload.healthy
        let rolling = workload.updated < workload.replicas
        KubeRow(
            icon: icon, iconColor: healthy ? colors.accent : Color(nsColor: .systemOrange),
            title: workload.name,
            subtitle: rolling && workload.replicas > 0 ? "updating \(workload.updated)/\(workload.replicas)" : nil,
            fontScale: fontScale, colors: colors
        ) {
            Text("\(workload.ready)/\(workload.replicas)")
                .font(fontScale.font(.xs).monospacedDigit())
                .foregroundStyle(healthy ? colors.muted.opacity(0.7) : Color(nsColor: .systemOrange))
        }
        .onTapGesture(count: 2) { store.logs(target) }
        .help("Double-click: follow logs · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(kind.resource) \(workload.name), \(workload.ready) of \(workload.replicas) ready")
        .contextMenu {
            Button("Follow Logs") { store.logs(target) }
            KubeInspectItems(target: target, name: workload.name)
            Divider()
            if kind != .daemonsets {
                Button("Scale…") { store.scale(kind, workload) }
            }
            Button("Rollout Restart…") { store.rolloutRestart(kind, workload) }
        }
    }
}

private struct KubeJobRow: View {
    let job: KubeJob
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    var body: some View {
        let (icon, color): (String, Color) =
            switch job.health {
            case .running: ("circle.dashed", Color(nsColor: .systemBlue))
            case .complete: ("checkmark.circle", colors.muted.opacity(0.6))
            case .failed: ("xmark.circle", Color(nsColor: .systemRed))
            }
        let subtitle =
            "\(job.succeeded)/\(job.completions) done" + (job.active > 0 ? " · \(job.active) active" : "")
            + (job.failed > 0 ? " · \(job.failed) failed" : "")
        KubeRow(icon: icon, iconColor: color, title: job.name, subtitle: subtitle, fontScale: fontScale, colors: colors)
        {
            if let created = job.createdAt {
                Text(formatCompactAge(created))
                    .font(fontScale.font(.xs).monospacedDigit())
                    .foregroundStyle(colors.muted.opacity(0.6))
            }
        }
        .onTapGesture(count: 2) { store.logs("job/" + job.name) }
        .help("Double-click: follow logs · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Job \(job.name), \(subtitle)")
        .contextMenu {
            Button("Follow Logs") { store.logs("job/" + job.name) }
            KubeInspectItems(target: "job/" + job.name, name: job.name)
            Divider()
            Button("Delete Job…") { store.delete(.jobs, name: job.name, info: "Its pods are deleted too.") }
        }
    }
}

private struct KubeCronJobRow: View {
    let cronJob: KubeCronJob
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    var body: some View {
        let subtitle =
            cronJob.schedule + (cronJob.suspended ? " · suspended" : "")
            + (cronJob.active > 0 ? " · \(cronJob.active) running" : "")
        KubeRow(
            icon: "clock.arrow.circlepath",
            iconColor: cronJob.suspended ? colors.muted.opacity(0.5) : colors.accent,
            title: cronJob.name, subtitle: subtitle, fontScale: fontScale, colors: colors
        ) {
            if let last = cronJob.lastSchedule {
                Text(formatCompactAge(last))
                    .font(fontScale.font(.xs).monospacedDigit())
                    .foregroundStyle(colors.muted.opacity(0.6))
                    .help("Last scheduled")
            }
        }
        .help("Right-click: actions")
        .accessibilityLabel("CronJob \(cronJob.name), \(subtitle)")
        .contextMenu {
            Button("Run Now…") { store.trigger(cronJob) }
            Button(cronJob.suspended ? "Resume" : "Suspend") { store.setSuspended(cronJob, !cronJob.suspended) }
            KubeInspectItems(target: "cronjob/" + cronJob.name, name: cronJob.name)
        }
    }
}

private struct KubeIngressRow: View {
    let ingress: KubeIngress
    let fontScale: SidebarFontScale
    let colors: KubeRowColors
    private var store: KubeStore { .shared }

    var body: some View {
        KubeRow(
            icon: "globe", iconColor: colors.muted.opacity(0.7), title: ingress.name,
            subtitle: ingress.hosts.isEmpty ? "no hosts" : ingress.hosts.joined(separator: ", "),
            fontScale: fontScale, colors: colors
        ) {
            if ingress.tls {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(colors.muted.opacity(0.6))
                    .help("TLS")
            }
        }
        .onTapGesture(count: 2) {
            if let host = ingress.hosts.first { store.openIngress(ingress, host: host) }
        }
        .help("Double-click: open the first host in the browser · right-click: actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ingress \(ingress.name), hosts \(ingress.hosts.joined(separator: ", "))")
        .contextMenu {
            ForEach(ingress.hosts, id: \.self) { host in
                Button("Open \(host)") { store.openIngress(ingress, host: host) }
            }
            if !ingress.hosts.isEmpty { Divider() }
            KubeInspectItems(target: "ingress/" + ingress.name, name: ingress.name)
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
            KubeInspectItems(target: "svc/" + service.name, name: service.name)
        }
    }
}
