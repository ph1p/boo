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
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout, .sidebarFont])

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar") {
                SettingStack(label: "Position") {
                    ThemedSegmentedPicker(selection: LayoutSettingsBindings.binding(\.sidebarPosition)) { $0.label }
                }

                SettingStack(label: "Tab bar") {
                    ThemedSegmentedPicker(selection: LayoutSettingsBindings.binding(\.sidebarTabBarPosition)) {
                        $0.label
                    }
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

            SidebarFontSection()

            Section(title: "Workspace Bar") {
                SettingStack(label: "Position", help: "Position of the workspace switcher bar.") {
                    ThemedSegmentedPicker(selection: LayoutSettingsBindings.binding(\.workspaceBarPosition)) {
                        $0.label
                    }
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
                        "A ⋯ button next to the tab bar's +, with record, split, zoom, profile and close in its menu. The unzoom button always shows while a pane is zoomed."
                ) {
                    ThemedSegmentedPicker(selection: LayoutSettingsBindings.binding(\.paneControlsVisibility)) {
                        $0.label
                    }
                }
            }

            Section(title: "Tab Overflow") {
                SettingStack(label: "Behavior", help: "How tabs behave when they exceed the available bar width.") {
                    ThemedSegmentedPicker(selection: LayoutSettingsBindings.binding(\.tabOverflowMode)) { $0.label }
                }
            }
        }
        .foregroundStyle(t.text)
    }
}

// MARK: - Sidebar Font

private struct SidebarFontSection: View {
    @Environment(\.tokens) private var tokens
    @State private var fontSize = Double(AppSettings.shared.sidebarFontSize)
    @State private var fontName =
        AppSettings.shared.sidebarFontName.isEmpty ? "System Default" : AppSettings.shared.sidebarFontName

    private let systemFonts = AppSettings.availableSystemFonts

    var body: some View {
        let t = tokens
        Section(title: "Sidebar Font") {
            SettingRow(label: "Family") {
                FontChooser(selectedFont: $fontName, fonts: systemFonts)
                    .onChange(of: fontName) { _, v in
                        AppSettings.shared.sidebarFontName = v == "System Default" ? "" : v
                    }
            }
            SettingRow(
                label: "Size",
                help: "Applied to file trees and content only — not to section headers."
            ) {
                FontSizePicker(value: $fontSize, range: 10...20)
                    .onChange(of: fontSize) { _, v in AppSettings.shared.sidebarFontSize = CGFloat(v) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Section Header")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(t.muted)
                let previewFont: Font = {
                    let name = fontName == "System Default" ? "" : fontName
                    if name.isEmpty { return .system(size: CGFloat(fontSize)) }
                    return .custom(name, size: CGFloat(fontSize))
                }()
                Text("  Documents").font(previewFont).foregroundStyle(t.text)
                Text("  Projects").font(previewFont).foregroundStyle(t.text)
                Text("  README.md").font(previewFont).foregroundStyle(t.muted)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(t.chromeBg))
        }
    }
}
