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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Segments")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.muted)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer()
                    Button("Reset Layout") { AppSettings.shared.resetStatusBarLayout() }
                        .buttonStyle(.themed)
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
                        + "Many segments only appear while they have something to show. "
                        + "When the window is narrow, the least important segments step aside."
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
                        move: { StatusBarLayout.moving($0, toLeft: left, atEnd: true, in: $1) }))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(t.separator, lineWidth: 0.5))
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
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? t.textSecondary : t.textTertiary)
            Text(info.displayName)
                .font(.system(size: 12))
                .foregroundStyle(isHidden ? t.textTertiary : t.text)
                .strikethrough(isHidden, color: t.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isMoved {
                Circle().fill(t.accent).frame(width: 4, height: 4)
                    .help("Moved from its default side")
            }
            Spacer(minLength: 4)
            IconButton(
                systemName: isHidden ? "eye.slash" : "eye", tint: isHidden ? t.textTertiary : t.textSecondary, size: 10,
                frame: 20, fillOpacity: 0, help: isHidden ? "Show in the status bar" : "Hide from the status bar"
            ) {
                AppSettings.shared.setStatusBarSegment(info.id, hidden: !isHidden)
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
