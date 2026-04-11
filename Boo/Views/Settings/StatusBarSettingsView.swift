import SwiftUI

// MARK: - Status Bar

struct StatusBarSettingsView: View {
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showConnection = AppSettings.shared.statusBarShowConnection
    @State private var showPath = AppSettings.shared.pluginBool("file-tree-local", "showPath", default: true)
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar, .plugins])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        SettingsPage(title: "Status Bar") {
            Section(title: "Preview") {
                statusBarPreview(t)
            }

            Section(title: "Built-in Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Connection", isOn: $showConnection)
                        .onChange(of: showConnection) { v in AppSettings.shared.statusBarShowConnection = v }
                    ToggleRow(label: "Current path", isOn: $showPath)
                        .onChange(of: showPath) { v in
                            AppSettings.shared.setPluginSetting("file-tree-local", "showPath", v, topic: .statusBar)
                        }
                    ToggleRow(label: "Pane & tab count", isOn: $showPaneInfo)
                        .onChange(of: showPaneInfo) { v in AppSettings.shared.statusBarShowPaneInfo = v }
                    ToggleRow(label: "Clock", isOn: $showTime)
                        .onChange(of: showTime) { v in AppSettings.shared.statusBarShowTime = v }
                }
            }

            pluginSegmentsSection(t)
        }
    }

    // MARK: - Plugin Segments (dynamic)

    @ViewBuilder
    private func pluginSegmentsSection(_ t: Tokens) -> some View {
        let manifests = PluginSettingsView.registeredManifests
            .filter { $0.capabilities?.statusBarSegment == true }
            .sorted { ($0.statusBar?.priority ?? 50) < ($1.statusBar?.priority ?? 50) }

        if !manifests.isEmpty {
            Section(title: "Plugin Segments") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(manifests, id: \.id) { manifest in
                        pluginSettingsRows(for: manifest, t: t)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pluginSettingsRows(for manifest: PluginManifest, t: Tokens) -> some View {
        let statusBarSettings = (manifest.settings ?? []).filter { $0.type == .bool }

        VStack(alignment: .leading, spacing: 6) {
            // Plugin header
            HStack(spacing: 6) {
                Image(systemName: manifest.icon)
                    .font(.system(size: 10))
                    .foregroundColor(t.accent)
                    .frame(width: 14)
                Text(manifest.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(t.text)
            }

            if statusBarSettings.isEmpty {
                HStack {
                    Text("Visible when active")
                        .font(.system(size: 11))
                        .foregroundColor(t.muted)
                    Spacer()
                }
                .padding(.leading, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(statusBarSettings, id: \.key) { setting in
                        PluginStatusBarToggle(pluginID: manifest.id, setting: setting)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Preview

    private func statusBarPreview(_ t: Tokens) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if showConnection {
                    statusChip(icon: "circle.fill", label: "local", color: Color.green, t: t)
                }
                if showPath {
                    statusChip(icon: "folder", label: "~/projects/boo", color: t.muted, t: t)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if showPaneInfo {
                    statusChip(icon: nil, label: "2 panes \u{00B7} 3 tabs", color: t.muted, t: t)
                }
                if showTime {
                    statusChip(icon: nil, label: "12:00", color: t.muted, t: t)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(t.chromeBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(t.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func statusChip(icon: String?, label: String, color: Color, t: Tokens) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(color)
        }
    }
}

// MARK: - Plugin Status Bar Toggle

private struct PluginStatusBarToggle: View {
    let pluginID: String
    let setting: PluginManifest.SettingManifest
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar, .plugins])

    var body: some View {
        let _ = observer.revision
        let value = AppSettings.shared.pluginBool(
            pluginID, setting.key, default: setting.defaultValue?.value as? Bool ?? false)
        ToggleRow(
            label: setting.label,
            isOn: Binding(
                get: { value },
                set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0, topic: .statusBar) }
            ))
    }
}
