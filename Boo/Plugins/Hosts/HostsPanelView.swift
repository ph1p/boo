import SwiftUI

struct HostsPanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    @ObservedObject var store = HostsStore.shared
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var filter = ""

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let mutedColor = Color(nsColor: theme.chromeMuted)
        let textColor = Color(nsColor: theme.chromeText)
        let accentColor = Color(nsColor: theme.accentColor)
        let groups = Self.grouped(store.hosts, filter: filter, recent: store.recent)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(mutedColor)
                TextField("Filter hosts", text: $filter)
                    .textFieldStyle(.plain)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(textColor)
                Button(action: { store.editInConfig(SSHHost(alias: "", file: store.path, line: 1)) }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(mutedColor)
                }
                .buttonStyle(.plain)
                .help("Edit ~/.ssh/config")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if store.hosts.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "server.rack")
                        .font(.system(size: 24))
                        .foregroundStyle(mutedColor.opacity(0.3))
                    Text("No hosts in ~/.ssh/config")
                        .font(fontScale.font(.base))
                        .foregroundStyle(mutedColor.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.name) { group in
                            if groups.count > 1 || group.name != nil {
                                Text((group.name ?? "Other").uppercased())
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(mutedColor.opacity(0.8))
                                    .tracking(0.6)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                            ForEach(group.hosts) { host in
                                HostRow(
                                    host: host,
                                    lastConnected: store.recent[host.alias],
                                    sessions: store.live[host.alias]?.count ?? 0,
                                    fontScale: fontScale,
                                    textColor: textColor,
                                    mutedColor: mutedColor,
                                    accentColor: accentColor)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear {
            store.start()
            store.refreshLive()
        }
    }

    struct Group {
        var name: String?
        var hosts: [SSHHost]
    }

    /// Named groups alphabetically, ungrouped hosts last; hosts by most
    /// recently connected, then file order.
    static func grouped(_ hosts: [SSHHost], filter: String, recent: [String: Date]) -> [Group] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = hosts.filter { host in
            query.isEmpty
                || ([host.alias, host.address, host.group ?? ""] + host.tags).contains {
                    $0.lowercased().contains(query)
                }
        }
        let byGroup = Dictionary(grouping: matching.enumerated(), by: { $0.element.group })
        return byGroup.map { name, entries in
            Group(
                name: name,
                hosts: entries.sorted {
                    let a = recent[$0.element.alias] ?? .distantPast
                    let b = recent[$1.element.alias] ?? .distantPast
                    return a != b ? a > b : $0.offset < $1.offset
                }.map(\.element))
        }.sorted {
            switch ($0.name, $1.name) {
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?): return a.localizedStandardCompare(b) == .orderedAscending
            }
        }
    }
}

private struct HostRow: View {
    let host: SSHHost
    let lastConnected: Date?
    let sessions: Int
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    @State private var isHovered = false

    private var store: HostsStore { .shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundStyle(sessions > 0 ? accentColor : mutedColor.opacity(0.6))
                .frame(width: 14)
                .overlay(alignment: .bottomTrailing) {
                    if sessions > 0 {
                        Circle()
                            .fill(Color(nsColor: .booLocal))
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: 2)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(host.alias)
                        .font(fontScale.font(.base).weight(sessions > 0 ? .semibold : .medium))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                    ForEach(host.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.8))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(accentColor.opacity(0.1))
                            .cornerRadius(3)
                    }
                }
                if host.address != host.alias {
                    Text(host.address)
                        .font(fontScale.font(.xs))
                        .foregroundStyle(mutedColor.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if sessions > 1 {
                Text("×\(sessions)")
                    .font(fontScale.font(.xs))
                    .foregroundStyle(mutedColor.opacity(0.7))
            }
            if let lastConnected {
                Text(formatCompactAge(lastConnected))
                    .font(fontScale.font(.xs).monospacedDigit())
                    .foregroundStyle(mutedColor.opacity(0.6))
                    .help("Last connected \(lastConnected.formatted(date: .abbreviated, time: .shortened))")
            }
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
        .onTapGesture {
            store.connect(host, split: NSEvent.modifierFlags.contains(.option))
        }
        .help("Click: connect in new tab · ⌥-click: connect in split")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(host.alias), \(host.address)\(sessions > 0 ? ", connected" : "")")
        .contextMenu {
            Button("Connect in New Tab") { store.connect(host, split: false) }
            Button("Connect in Split") { store.connect(host, split: true) }
            if sessions > 0 {
                Button("Go to Session") { store.jumpToSession(host) }
            }
            Divider()
            Button("Copy ssh Command") {
                PluginActions.copyToPasteboard(HostsStore.command(for: host))
            }
            Button("Edit in Config") { store.editInConfig(host) }
        }
    }
}
