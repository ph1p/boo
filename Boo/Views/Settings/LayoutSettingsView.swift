import SwiftUI

// MARK: - Layout

struct LayoutSettingsView: View {
    @State private var sidebarPosition = AppSettings.shared.sidebarPosition
    @State private var sidebarDefaultHidden = AppSettings.shared.sidebarDefaultHidden
    @State private var sidebarTabBarPosition = AppSettings.shared.sidebarTabBarPosition
    @State private var sidebarGlobalState = AppSettings.shared.sidebarGlobalState
    @State private var workspaceBarPosition = AppSettings.shared.workspaceBarPosition
    @State private var tabOverflowMode = AppSettings.shared.tabOverflowMode
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar") {
                Picker("Position", selection: $sidebarPosition) {
                    ForEach(SidebarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sidebarPosition) { v in AppSettings.shared.sidebarPosition = v }

                Picker("Tab Bar", selection: $sidebarTabBarPosition) {
                    ForEach(SidebarTabBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sidebarTabBarPosition) { v in AppSettings.shared.sidebarTabBarPosition = v }

                ToggleRow(label: "Hide sidebar by default", isOn: $sidebarDefaultHidden)
                    .onChange(of: sidebarDefaultHidden) { v in AppSettings.shared.sidebarDefaultHidden = v }
                ToggleRow(label: "Independent sidebar state", isOn: $sidebarGlobalState)
                    .onChange(of: sidebarGlobalState) { v in AppSettings.shared.sidebarGlobalState = v }
                Text(
                    "When on, the sidebar keeps its own state across all terminals — switching tabs or panes does not change the active plugin, expanded sections, or scroll position."
                )
                .font(.system(size: 11))
                .foregroundColor(t.muted)
                Text("Toggle the sidebar with \u{2318}B.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Workspace Bar") {
                Picker("", selection: $workspaceBarPosition) {
                    ForEach(WorkspaceBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: workspaceBarPosition) { v in AppSettings.shared.workspaceBarPosition = v }
                Text("Position of the workspace switcher bar.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Tab Overflow") {
                Picker("", selection: $tabOverflowMode) {
                    ForEach(TabOverflowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tabOverflowMode) { v in AppSettings.shared.tabOverflowMode = v }
                Text("How tabs behave when they exceed the available bar width.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }
        }
        .foregroundColor(t.text)
    }
}
