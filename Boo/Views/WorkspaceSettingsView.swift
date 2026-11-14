import SwiftUI

/// Sheet that edits what one workspace overrides from the global settings.
/// Every change applies at once; a field left on Inherit follows Settings.
struct WorkspaceSettingsView: View {
    struct SidebarTabOption: Equatable {
        let id: String
        let label: String
    }

    let name: String
    @State var settings: WorkspaceSettings
    let profiles: [String]
    let sidebarTabs: [SidebarTabOption]
    let segments: [StatusBarView.SegmentInfo]
    /// Seeds the workspace's list when the status bar override is switched on.
    let globallyHiddenSegments: [String]
    let onChange: (WorkspaceSettings) -> Void
    let onDone: () -> Void
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.text)
                Text("\(name): what is left on Inherit follows the app settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }

            Section(title: "Profile") {
                if profiles.isEmpty {
                    SettingRow(label: "Default profile") {
                        Text("No profiles yet").font(.system(size: 12)).foregroundStyle(t.muted)
                    }
                } else {
                    InheritableField(
                        label: "Default profile", help: "For tabs that no rule gives a profile.",
                        value: $settings.defaultProfile, fallback: profiles[0]
                    ) { ThemedMenuPicker(selection: $0, options: profiles, width: 180) { $0 } }
                }
            }

            Section(title: "Layout") {
                InheritableField(
                    label: "Sidebar position", value: enumBinding(\.sidebarPosition),
                    fallback: AppSettings.shared.sidebarPosition
                ) { ThemedSegmentedPicker(selection: $0) { $0.label } }
                InheritableField(
                    label: "Tabs", value: enumBinding(\.tabOverflowMode), fallback: AppSettings.shared.tabOverflowMode
                ) { ThemedSegmentedPicker(selection: $0) { $0.label } }
                if let first = sidebarTabs.first {
                    InheritableField(
                        label: "Sidebar tab", help: "Shown first when this workspace opens.",
                        value: $settings.sidebarDefaultTab, fallback: first.id
                    ) { selection in
                        ThemedMenuPicker(selection: selection, options: sidebarTabs.map(\.id), width: 180) { id in
                            sidebarTabs.first { $0.id == id }?.label ?? id
                        }
                    }
                }
            }

            Section(title: "Status Bar") {
                InheritableField(
                    label: "Segments", value: $settings.statusBarHiddenSegments, fallback: globallyHiddenSegments
                ) { _ in EmptyView() }
                if settings.statusBarHiddenSegments != nil {
                    ForEach(segments) { segment in
                        ToggleRow(label: segment.displayName, isOn: segmentBinding(segment.id))
                    }
                }
            }

            HStack {
                Button("Reset All") { settings = WorkspaceSettings() }
                    .disabled(settings.isEmpty)
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.themedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.themed)
        }
        .padding(20)
        .frame(width: 460)
        .background(t.bg)
        .onChange(of: settings) { _, value in onChange(value) }
    }

    /// A raw-value field of `WorkspaceSettings` as its enum.
    private func enumBinding<E: RawRepresentable>(
        _ keyPath: WritableKeyPath<WorkspaceSettings, Int?>
    ) -> Binding<E?> where E.RawValue == Int {
        Binding(
            get: { settings[keyPath: keyPath].flatMap(E.init(rawValue:)) },
            set: { settings[keyPath: keyPath] = $0?.rawValue })
    }

    private func segmentBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !(settings.statusBarHiddenSegments ?? []).contains(id) },
            set: { shown in
                var list = (settings.statusBarHiddenSegments ?? []).filter { $0 != id }
                if !shown { list.append(id) }
                settings.statusBarHiddenSegments = list
            })
    }
}
