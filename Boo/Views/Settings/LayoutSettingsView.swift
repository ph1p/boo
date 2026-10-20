import SwiftUI

// MARK: - Layout

enum LayoutSettingsBindings {
    static func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        nonisolated(unsafe) let kp = keyPath
        return Binding(
            get: { AppSettings.shared[keyPath: kp] },
            set: { AppSettings.shared[keyPath: kp] = $0 }
        )
    }
}

struct LayoutSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar") {
                SettingStack(label: "Position") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.sidebarPosition)) {
                        ForEach(SidebarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                SettingStack(label: "Tab bar") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.sidebarTabBarPosition)) {
                        ForEach(SidebarTabBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                ToggleRow(
                    label: "Hide sidebar by default",
                    help: "Toggle the sidebar with \u{2318}B.",
                    isOn: LayoutSettingsBindings.binding(\.sidebarDefaultHidden)
                )
                ToggleRow(
                    label: "Share plugin sidebar state globally",
                    help:
                        "When on, the sidebar keeps its own state across all terminals — switching tabs or panes does not change the active plugin, expanded sections, or scroll position.",
                    isOn: LayoutSettingsBindings.binding(\.sidebarGlobalState)
                )
                ToggleRow(
                    label: "Remember width and visibility per workspace",
                    help:
                        "When on, each workspace keeps its own sidebar width and visibility. When off, all workspaces share one width and visibility state.",
                    isOn: LayoutSettingsBindings.binding(\.sidebarPerWorkspaceState)
                )
            }

            Section(title: "Workspace Bar") {
                SettingStack(label: "Position", help: "Position of the workspace switcher bar.") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.workspaceBarPosition)) {
                        ForEach(WorkspaceBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                ToggleRow(
                    label: "Color new workspaces by project",
                    help:
                        "Each new workspace gets a color derived from its git repository (or folder), the same every time. A color you pick yourself wins.",
                    isOn: LayoutSettingsBindings.binding(\.autoColorWorkspaces)
                )
                ToggleRow(
                    label: "Edit name and color of new workspaces",
                    help: "Opens the inline editor right after ⌘N. Double-click a workspace to edit it any time.",
                    isOn: LayoutSettingsBindings.binding(\.openWorkspaceEditorOnCreate)
                )
            }

            Section(title: "Tab Groups") {
                ToggleRow(
                    label: "Edit name and color of new groups",
                    help:
                        "Opens the inline editor when a group is created. Right-click a group chip to edit it any time.",
                    isOn: LayoutSettingsBindings.binding(\.openGroupEditorOnCreate)
                )
                ToggleRow(
                    label: "New tabs join the active group",
                    help: "A tab opened while a grouped tab is active is added to that group.",
                    isOn: LayoutSettingsBindings.binding(\.newTabsJoinActiveGroup)
                )
            }

            Section(title: "Pane Controls") {
                SettingStack(
                    label: "Show",
                    help:
                        "Record, split, zoom and close buttons in a pane's top-right corner. A running recording's timer always shows."
                ) {
                    Picker("", selection: LayoutSettingsBindings.binding(\.paneControlsVisibility)) {
                        ForEach(PaneControlsVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            Section(title: "Recording") {
                ToggleRow(
                    label: "Highlight recording panes",
                    help: "Draws a red frame around every pane whose terminal is being recorded.",
                    isOn: LayoutSettingsBindings.binding(\.highlightRecordingPane)
                )
                SettingStack(label: "When a recording stops") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.recordingStopAction)) {
                        ForEach(RecordingStopAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                SettingStack(label: "Save recordings to") {
                    HStack(spacing: 8) {
                        Text((SessionRecorder.recordingsDirectory.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(t.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = SessionRecorder.recordingsDirectory
                            panel.message = "Choose where terminal recordings are saved"
                            if panel.runModal() == .OK, let url = panel.url {
                                FolderBookmarkStore.shared.save(url)
                                AppSettings.shared.recordingsFolder = url.path
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Reset") {
                            AppSettings.shared.recordingsFolder = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(AppSettings.shared.recordingsFolder.isEmpty)
                    }
                }
            }

            Section(title: "Tab Overflow") {
                SettingStack(label: "Behavior", help: "How tabs behave when they exceed the available bar width.") {
                    Picker("", selection: LayoutSettingsBindings.binding(\.tabOverflowMode)) {
                        ForEach(TabOverflowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
        .foregroundStyle(t.text)
    }
}
