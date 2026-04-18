import SwiftUI

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])
    @State private var searchText: String = ""

    private static let groups: [(String, [(String, String)])] = [
        (
            "General",
            [
                ("Settings", "\u{2318},"),
                ("New Workspace", "\u{2318}N"),
                ("Open Folder", "\u{21E7}\u{2318}O"),
                ("New Tab", "\u{2318}T"),
                ("Close", "\u{2318}W"),
                ("Reopen Tab", "\u{2318}Z"),
                ("Close Pane", "\u{21E7}\u{2318}W"),
                ("Switch Workspace 1-9", "\u{2318}1-9")
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
                ("Focus Previous Pane", "\u{2318}[")
            ]
        ),
        (
            "View",
            [
                ("Toggle Sidebar", "\u{2318}B"),
                ("Increase Font", "\u{2318}+"),
                ("Decrease Font", "\u{2318}-"),
                ("Reset Font", "\u{2318}0")
            ]
        ),
        (
            "Edit",
            [
                ("Copy", "\u{2318}C"),
                ("Paste", "\u{2318}V"),
                ("Select All", "\u{2318}A")
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                TextField("Filter shortcuts", text: $searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .foregroundStyle(t.text)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(t.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(t.chromeBg)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.border.opacity(0.6), lineWidth: 0.5))
            )

            if filteredGroups.isEmpty {
                Text("No shortcuts matching \"\(searchText)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                ForEach(filteredGroups, id: \.0) { group in
                    shortcutGroup(title: group.0, items: group.1, tokens: t)
                }
            }
        }
    }

    private func shortcutGroup(title: String, items: [(String, String)], tokens t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.muted)
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                    Spacer()
                    Text(item.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(t.accent.opacity(0.1))
                        )
                }
            }
        }
    }
}
