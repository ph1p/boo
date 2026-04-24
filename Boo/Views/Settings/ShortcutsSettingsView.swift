import SwiftUI

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])
    @State private var searchText: String = ""

    static let groups: [(String, [(String, String)])] = [
        (
            "General",
            [
                ("Settings", "\u{2318},"),
                ("New Workspace", "\u{2318}N"),
                ("Open Folder", "\u{21E7}\u{2318}O"),
                ("New Terminal Tab", "\u{2318}T"),
                ("New Browser Tab", "\u{21E7}\u{2318}T"),
                ("Save", "\u{2318}S"),
                ("Close", "\u{2318}W"),
                ("Reopen Closed Tab", "\u{2325}\u{2318}Z"),
                ("Close Pane", "\u{21E7}\u{2318}W"),
                ("Switch Workspace 1-9", "\u{2318}1-9"),
                ("Switch Tab 1-9", "\u{2325}\u{2318}1-9")
            ]
        ),
        (
            "Terminal",
            [
                ("Clear Screen", "\u{2318}K"),
                ("Clear Scrollback", "\u{21E7}\u{2318}K"),
                ("Split Right", "\u{2318}D"),
                ("Split Down", "\u{21E7}\u{2318}D"),
                ("Focus Next Pane", "\u{2318}]"),
                ("Focus Previous Pane", "\u{2318}["),
                ("Equalize Splits", "\u{2303}\u{2318}="),
                ("Increase Font Size", "\u{2318}+"),
                ("Decrease Font Size", "\u{2318}-"),
                ("Reset Font Size", "\u{2318}0")
            ]
        ),
        (
            "View",
            [
                ("Toggle Sidebar", "\u{2318}B"),
                ("Toggle Full Screen", "\u{2318}\u{23CE}"),
                ("Toggle Full Screen", "\u{2303}\u{2318}F")
            ]
        ),
        (
            "Edit",
            [
                ("Undo", "\u{2318}Z"),
                ("Redo", "\u{21E7}\u{2318}Z"),
                ("Cut", "\u{2318}X"),
                ("Copy", "\u{2318}C"),
                ("Paste", "\u{2318}V"),
                ("Select All", "\u{2318}A"),
                ("Find…", "\u{2318}F")
            ]
        ),
        (
            "Bookmarks",
            [
                ("Bookmark Directory", "\u{21E7}\u{2318}B"),
                ("Jump to Bookmark 1-9", "\u{2303}1-9")
            ]
        )
    ]

    private var filteredGroups: [(String, [(String, String)])] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.groups }
        return Self.groups.compactMap { group in
            let matchingItems = group.1.filter {
                $0.0.lowercased().contains(q) || $0.1.lowercased().contains(q)
            }
            return matchingItems.isEmpty ? nil : (group.0, matchingItems)
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

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
                ForEach(filteredGroups, id: \.0) { group in
                    Section(title: group.0) {
                        ForEach(Array(group.1.enumerated()), id: \.offset) { _, item in
                            shortcutRow(label: item.0, binding: item.1, t: t)
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
