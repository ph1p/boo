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
            return matchingItems.isEmpty ? nil : ActionRegistry.ShortcutGroup(title: group.title, entries: matchingItems)
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Keyboard Shortcuts") {
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
        .padding(.vertical, 2)
    }
}
