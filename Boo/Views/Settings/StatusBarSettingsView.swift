import SwiftUI

// MARK: - Status Bar

struct StatusBarSettingsView: View {
    @Environment(\.tokens) private var tokens
    @StateObject private var observer = SettingsObserver(topics: [.theme, .statusBar, .plugins])

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

    @State private var draggingID: String?

    var body: some View {
        let _ = observer.revision
        let t = tokens
        let bar = sourceBar
        let arrangement = bar.arrangement()
        let catalog = bar.segmentCatalog
        SettingsPage(title: "Status Bar") {
            Section(title: "Preview", footer: "When the window is narrow, the least important segments step aside.") {
                statusBarPreview(arrangement, catalog: catalog, t: t)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Segments")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.muted)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer()
                    Button("Reset Layout") { AppSettings.shared.resetStatusBarLayout() }
                        .controlSize(.small)
                        .help("Restore the built-in order and sides. Visibility is kept.")
                }
                .padding(.horizontal, 2)
                HStack(alignment: .top, spacing: 10) {
                    segmentColumn(left: true, arrangement: arrangement, catalog: catalog, t: t)
                    segmentColumn(left: false, arrangement: arrangement, catalog: catalog, t: t)
                }
                .animation(.easeOut(duration: 0.15), value: arrangement)
                Text(
                    "Drag a segment to reorder it or move it to the other side. The eye hides it. "
                        + "Many segments only appear while they have something to show."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
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

    // MARK: - Segment columns

    /// One side of the bar as a drop zone. Rows reorder live while dragging;
    /// dropping on the empty space below the rows puts the segment last.
    private func segmentColumn(
        left: Bool, arrangement: StatusBarLayout.Arrangement, catalog: [String: StatusBarView.SegmentInfo], t: Tokens
    ) -> some View {
        let rows = (left ? arrangement.left : arrangement.right).compactMap { catalog[$0] }
        let current = { sourceBar.arrangement() }
        return VStack(alignment: .leading, spacing: 4) {
            Text(left ? "Left" : "Right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.textSecondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(rows) { info in
                SegmentRow(
                    info: info, isHidden: AppSettings.shared.isStatusBarSegmentHidden(info.id),
                    isMoved: info.isLeftByDefault != left
                )
                .onDrag {
                    draggingID = info.id
                    return NSItemProvider(object: info.id as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: SegmentDropDelegate(
                        dragging: $draggingID, current: current,
                        move: { StatusBarLayout.moving($0, onto: info.id, in: $1) }))
            }
            if rows.isEmpty {
                Text("Drop segments here")
                    .font(.system(size: 11))
                    .foregroundStyle(t.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            // Room below the rows that takes "put it last" drops.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(
                    of: [.plainText],
                    delegate: SegmentDropDelegate(
                        dragging: $draggingID, current: current,
                        move: { id, arrangement in
                            let side = left ? arrangement.left : arrangement.right
                            return side.last == id
                                ? arrangement : StatusBarLayout.moving(id, toEndOfLeft: left, in: arrangement)
                        }))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(t.separator, lineWidth: 0.5))
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
            // Like the real bar: the right group keeps its room, the left one is cut.
            .frame(minWidth: 0, alignment: .leading)
            .clipped()
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                ForEach(right) { previewChip($0, t: t) }
            }
            .layoutPriority(1)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The chips are fixed-size, so with many segments the row is wider than
        // the page. Take only the offered width and clip the rest; otherwise the
        // row widens the whole settings page past the window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
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

/// One segment in a side column: a drag handle, its name, and an eye button
/// that shows or hides it.
private struct SegmentRow: View {
    @Environment(\.tokens) private var tokens
    let info: StatusBarView.SegmentInfo
    /// Passed in rather than read in `body`: SwiftUI only re-renders a row when
    /// its inputs change, so a value read from AppSettings here would go stale.
    let isHidden: Bool
    let isMoved: Bool
    @State private var hovered = false

    var body: some View {
        let t = tokens
        let id = info.id
        let hidden = isHidden
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? t.textSecondary : t.textTertiary)
            Text(info.displayName)
                .font(.system(size: 12))
                .foregroundStyle(hidden ? t.textTertiary : t.text)
                .strikethrough(hidden, color: t.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isMoved {
                Circle().fill(t.accent).frame(width: 4, height: 4)
                    .help("Moved from its default side")
            }
            Spacer(minLength: 4)
            IconButton(
                systemName: hidden ? "eye.slash" : "eye", tint: hidden ? t.textTertiary : t.textSecondary, size: 10,
                frame: 20, fillOpacity: 0, help: hidden ? "Show in the status bar" : "Hide from the status bar"
            ) {
                AppSettings.shared.setStatusBarSegment(id, hidden: !hidden)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? t.hoverFill : t.subtleFill.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Drop Delegate

/// Moves the dragged segment as soon as it enters a target, so the columns
/// show the result while the drag is still going.
private struct SegmentDropDelegate: DropDelegate {
    @Binding var dragging: String?
    let current: () -> StatusBarLayout.Arrangement
    let move: (String, StatusBarLayout.Arrangement) -> StatusBarLayout.Arrangement

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        let before = current()
        let after = move(dragging, before)
        if after != before { StatusBarView.save(after) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
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
