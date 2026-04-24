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
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

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
