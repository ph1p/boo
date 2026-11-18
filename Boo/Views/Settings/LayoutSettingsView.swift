import SwiftUI

// MARK: - Layout

struct LayoutSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar") {
                SettingStack(label: "Position") {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.sidebarPosition)) { $0.label }
                }

                SettingStack(label: "Tab bar") {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.sidebarTabBarPosition)) {
                        $0.label
                    }
                }

                ToggleRow(
                    label: "Hide sidebar by default",
                    help: "Toggle the sidebar with \u{2318}B.",
                    isOn: SettingsBindings.binding(\.sidebarDefaultHidden)
                )
                ToggleRow(
                    label: "Share plugin sidebar state globally",
                    help:
                        "When on, the sidebar keeps its own state across all terminals — switching tabs or panes does not change the active plugin, expanded sections, or scroll position.",
                    isOn: SettingsBindings.binding(\.sidebarGlobalState)
                )
                SettingStack(
                    label: "Remember width and visibility per",
                    help:
                        "Window: one sidebar state for all workspaces. Workspace: each workspace keeps its own. Tab: each tab keeps its own, and a new tab starts with the current state."
                ) {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.sidebarStateScope)) {
                        $0.label
                    }
                }
            }

            Section(title: "Workspace Bar") {
                SettingStack(label: "Position", help: "Position of the workspace switcher bar.") {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.workspaceBarPosition)) {
                        $0.label
                    }
                }
                ToggleRow(
                    label: "Color new workspaces by project",
                    help:
                        "Each new workspace gets a color derived from its git repository (or folder), the same every time. A color you pick yourself wins.",
                    isOn: SettingsBindings.binding(\.autoColorWorkspaces)
                )
                ToggleRow(
                    label: "Edit name and color of new workspaces",
                    help: "Opens the inline editor right after ⌘N. Double-click a workspace to edit it any time.",
                    isOn: SettingsBindings.binding(\.openWorkspaceEditorOnCreate)
                )
            }

            Section(title: "Tab Groups") {
                ToggleRow(
                    label: "Edit name and color of new groups",
                    help:
                        "Opens the inline editor when a group is created. Right-click a group chip to edit it any time.",
                    isOn: SettingsBindings.binding(\.openGroupEditorOnCreate)
                )
                ToggleRow(
                    label: "New tabs join the active group",
                    help: "A tab opened while a grouped tab is active is added to that group.",
                    isOn: SettingsBindings.binding(\.newTabsJoinActiveGroup)
                )
            }

            Section(title: "Pane Controls") {
                SettingStack(
                    label: "Show",
                    help:
                        "A ⋯ button next to the tab bar's +, with record, split, zoom, profile and close in its menu. The unzoom button always shows while a pane is zoomed."
                ) {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.paneControlsVisibility)) {
                        $0.label
                    }
                }
            }

            Section(title: "Tab Overflow") {
                SettingStack(label: "Behavior", help: "How tabs behave when they exceed the available bar width.") {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.tabOverflowMode)) { $0.label }
                }
            }
        }
        .foregroundStyle(t.text)
    }
}
