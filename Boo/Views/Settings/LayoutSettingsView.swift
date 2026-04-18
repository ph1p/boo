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
                Picker("Position", selection: LayoutSettingsBindings.binding(\.sidebarPosition)) {
                    ForEach(SidebarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Tab Bar", selection: LayoutSettingsBindings.binding(\.sidebarTabBarPosition)) {
                    ForEach(SidebarTabBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                ToggleRow(
                    label: "Hide sidebar by default", isOn: LayoutSettingsBindings.binding(\.sidebarDefaultHidden))
                ToggleRow(
                    label: "Share plugin sidebar state globally",
                    isOn: LayoutSettingsBindings.binding(\.sidebarGlobalState))
                Text(
                    "When on, the sidebar keeps its own state across all terminals — switching tabs or panes does not change the active plugin, expanded sections, or scroll position."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                ToggleRow(
                    label: "Remember width and visibility per workspace",
                    isOn: LayoutSettingsBindings.binding(\.sidebarPerWorkspaceState)
                )
                Text(
                    "When on, each workspace keeps its own sidebar width and visibility. When off, all workspaces share one width and visibility state."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                Text("Toggle the sidebar with \u{2318}B.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }

            Section(title: "Workspace Bar") {
                Picker("", selection: LayoutSettingsBindings.binding(\.workspaceBarPosition)) {
                    ForEach(WorkspaceBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Position of the workspace switcher bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }

            Section(title: "Tab Overflow") {
                Picker("", selection: LayoutSettingsBindings.binding(\.tabOverflowMode)) {
                    ForEach(TabOverflowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("How tabs behave when they exceed the available bar width.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
        }
        .foregroundStyle(t.text)
    }
}
