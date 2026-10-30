import SwiftUI

// MARK: - Status Bar

struct StatusBarSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar, .plugins])

    /// Bar whose registered segments the page lists. Any open window's bar has
    /// the same built-ins plus the plugin segments of that window; with no
    /// window open a detached bar supplies the built-ins.
    private var sourceBar: StatusBarView {
        if let bar = (WindowManager.shared.activeController ?? WindowManager.shared.controllers.first)?.statusBar {
            return bar
        }
        return Self.fallbackBar
    }
    private static let fallbackBar = StatusBarView(frame: .zero)

    var body: some View {
        let _ = observer.revision
        let t = tokens
        let bar = sourceBar
        let arrangement = bar.arrangement()
        let catalog = bar.segmentCatalog
        SettingsPage(title: "Status Bar") {
            Section(
                title: "Preview",
                footer: "Right-click the status bar to hide or move a segment. When the window is narrow, "
                    + "the least important segments step aside until there is room again."
            ) {
                statusBarPreview(arrangement, catalog: catalog, t: t)
            }

            Section(title: "Left Side") {
                segmentList(arrangement.left, arrangement: arrangement, catalog: catalog)
            }

            Section(title: "Right Side") {
                segmentList(arrangement.right, arrangement: arrangement, catalog: catalog)
            }

            HStack {
                Spacer()
                Button("Reset Layout") { AppSettings.shared.resetStatusBarLayout() }
                    .controlSize(.small)
                    .help("Restore the built-in order and sides. Visibility is kept.")
            }

            Section(title: "Appearance") {
                SettingStack(label: "Clock") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.statusBarClockFormat)) {
                        ForEach(StatusBarClockFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                SettingStack(label: "Path", help: Self.pathHelp(AppSettings.shared.statusBarPathStyle)) {
                    Picker("", selection: LayoutSettingsBindings.binding(\.statusBarPathStyle)) {
                        ForEach(StatusBarPathStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                SettingRow(label: "Branch name length", help: "Longer branch names are cut off with an ellipsis.") {
                    Stepper(value: LayoutSettingsBindings.binding(\.statusBarBranchMaxLength), in: 4...80, step: 2) {
                        Text("\(AppSettings.shared.statusBarBranchMaxLength) characters")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    .controlSize(.small)
                }
                ToggleRow(
                    label: "Separators",
                    help: "Thin lines between the segments on the left side.",
                    isOn: LayoutSettingsBindings.binding(\.statusBarSeparators)
                )
            }

            pluginSegmentsSection(t)
        }
    }

    private static func pathHelp(_ style: StatusBarPathStyle) -> String {
        let sample = NSHomeDirectory() + "/projects/boo/Sources"
        return "Shown as \(PathSegment.display(sample, style: style))"
    }

    // MARK: - Segment lists

    @ViewBuilder
    private func segmentList(
        _ ids: [String], arrangement: StatusBarLayout.Arrangement, catalog: [String: StatusBarView.SegmentInfo]
    ) -> some View {
        let rows = ids.compactMap { catalog[$0] }
        if rows.isEmpty {
            DescriptionLabel(text: "No segments. Move one here with its arrow button.")
        } else {
            VStack(spacing: 6) {
                ForEach(rows) { SegmentRow(info: $0, arrangement: arrangement) }
            }
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

        PluginSegmentGroup(icon: manifest.icon, name: manifest.name) {
            if statusBarSettings.isEmpty {
                Text("Visible when active")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            } else {
                ForEach(statusBarSettings, id: \.key) { setting in
                    PluginStatusBarToggle(pluginID: manifest.id, setting: setting)
                }
            }
        }
    }

    // MARK: - Preview

    private func statusBarPreview(
        _ arrangement: StatusBarLayout.Arrangement, catalog: [String: StatusBarView.SegmentInfo], t: Tokens
    ) -> some View {
        let settings = AppSettings.shared
        func shown(_ ids: [String]) -> [StatusBarView.SegmentInfo] {
            ids.compactMap { catalog[$0] }.filter { !settings.isStatusBarSegmentHidden($0.id) }
        }
        let left = shown(arrangement.left)
        let right = shown(arrangement.right)
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(Array(left.enumerated()), id: \.element.id) { index, info in
                    if index > 0 && settings.statusBarSeparators {
                        Rectangle().fill(t.separator).frame(width: 0.5, height: 10)
                    }
                    previewChip(info, t: t)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                ForEach(right) { previewChip($0, t: t) }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(t.chromeBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(t.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func previewChip(_ info: StatusBarView.SegmentInfo, t: Tokens) -> some View {
        Text(Self.sampleText(for: info))
            .font(.system(size: 10))
            .foregroundStyle(t.muted)
            .fixedSize()
    }

    /// Representative content for built-ins, the segment name otherwise.
    private static func sampleText(for info: StatusBarView.SegmentInfo) -> String {
        let settings = AppSettings.shared
        switch info.id {
        case "environment": return "\u{25CF} local"
        case "path":
            return PathSegment.display(NSHomeDirectory() + "/projects/boo", style: settings.statusBarPathStyle)
        case "git-branch": return "main"
        case "pane-info": return "2 panes \u{00B7} 3 tabs"
        case "time": return settings.statusBarClockFormat.string(from: Date())
        default: return info.displayName
        }
    }
}

// MARK: - Segment Row

/// One segment in a side list: visibility, order within the side, and a
/// button that moves it to the other side.
private struct SegmentRow: View {
    @Environment(\.tokens) private var tokens
    let info: StatusBarView.SegmentInfo
    let arrangement: StatusBarLayout.Arrangement

    var body: some View {
        let settings = AppSettings.shared
        let isLeft = arrangement.left.contains(info.id)
        let side = isLeft ? arrangement.left : arrangement.right
        let visible = Binding(
            get: { !settings.isStatusBarSegmentHidden(info.id) },
            set: { settings.setStatusBarSegment(info.id, hidden: !$0) })
        HStack(spacing: 8) {
            Toggle(info.displayName, isOn: visible)
                .toggleStyle(.themedCheckbox)
                .font(.system(size: 12))
                .foregroundStyle(visible.wrappedValue ? tokens.text : tokens.muted)
            if info.isLeftByDefault != isLeft {
                Text("moved")
                    .font(.system(size: 10))
                    .foregroundStyle(tokens.muted)
            }
            Spacer(minLength: 8)
            moveButton("chevron.left", help: "Move left", disabled: side.first == info.id) {
                StatusBarLayout.moving(info.id, by: -1, in: arrangement)
            }
            moveButton("chevron.right", help: "Move right", disabled: side.last == info.id) {
                StatusBarLayout.moving(info.id, by: 1, in: arrangement)
            }
            moveButton(
                isLeft ? "arrow.right.to.line" : "arrow.left.to.line",
                help: isLeft ? "Move to the right side" : "Move to the left side", disabled: false
            ) {
                StatusBarLayout.moving(info.id, toLeft: !isLeft, in: arrangement)
            }
        }
    }

    private func moveButton(
        _ symbol: String, help: String, disabled: Bool, to target: @escaping () -> StatusBarLayout.Arrangement
    ) -> some View {
        IconButton(
            systemName: symbol, tint: disabled ? tokens.textTertiary : tokens.textSecondary, size: 10, frame: 18,
            fillOpacity: 0, help: help
        ) { StatusBarView.save(target()) }
        .disabled(disabled)
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
