import SwiftUI

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])
    @State private var searchText: String = ""

    /// Generated from the live main menu, so it cannot drift from it.
    private var filteredGroups: [ActionRegistry.ShortcutGroup] {
        let groups = ActionRegistry.shortcutGroups()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let matchingItems = group.entries.filter {
                $0.title.lowercased().contains(q) || $0.shortcut.lowercased().contains(q)
            }
            return matchingItems.isEmpty
                ? nil : ActionRegistry.ShortcutGroup(title: group.title, entries: matchingItems)
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Keyboard Shortcuts") {
            QuickTerminalSettingsSection()

            SettingTextField(
                placeholder: "Filter shortcuts",
                text: $searchText,
                icon: "magnifyingglass",
                trailingClear: true
            )

            if filteredGroups.isEmpty {
                Text("No shortcuts matching \"\(searchText)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                ForEach(filteredGroups, id: \.title) { group in
                    Section(title: group.title) {
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, item in
                            shortcutRow(label: item.title, binding: item.shortcut, t: t)
                        }
                    }
                }
            }
        }
    }

    private func shortcutRow(label: String, binding: String, t: Tokens) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(t.text)
            Spacer()
            ShortcutPill(text: binding)
        }
    }
}

// MARK: - Quick Terminal

struct QuickTerminalSettingsSection: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver()
    @State private var hotkey = AppSettings.shared.quickTerminalHotkey

    var body: some View {
        let _ = observer.revision
        let t = tokens
        let settings = AppSettings.shared

        Section(title: "Quick Terminal") {
            ToggleRow(
                label: "Global hotkey",
                help: "Drops a terminal down from the top of the screen, from any app.",
                isOn: LayoutSettingsBindings.binding(\.quickTerminalEnabled)
            )
            SettingRow(
                label: "Shortcut",
                help: "Like opt+space, ctrl+`, cmd+shift+t or f12. Press Return to apply."
            ) {
                HStack(spacing: 8) {
                    SettingTextField(
                        placeholder: "opt+space", text: $hotkey, monospaced: true, width: 160,
                        onCommit: { settings.quickTerminalHotkey = hotkey.trimmingCharacters(in: .whitespaces) })
                    if let spec = HotKeySpec.parse(settings.quickTerminalHotkey) {
                        ShortcutPill(text: spec.display)
                    }
                }
            }
            if settings.quickTerminalEnabled, let problem = QuickTerminalController.shared.hotKeyProblem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: settings.theme.error))
            }
            SettingRow(label: "Height") {
                HStack(spacing: 8) {
                    Slider(value: LayoutSettingsBindings.binding(\.quickTerminalHeight), in: 0.2...0.9, step: 0.05)
                    Text("\(Int((settings.quickTerminalHeight * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(t.muted)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            ToggleRow(
                label: "Hide when it loses focus",
                help: "Hiding keeps the shells running.",
                isOn: LayoutSettingsBindings.binding(\.quickTerminalHideOnResign)
            )
        }
    }
}
