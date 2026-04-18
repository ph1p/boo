import SwiftUI

struct BookmarksPanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var bookmarks: [BookmarkService.Bookmark] = []
    var namespace: String = "local"
    var onBookmarkSelected: ((String) -> Void)?
    var onBookmarkCurrent: (() -> Void)?
    var currentDirectory: String = ""

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let mutedColor = Color(nsColor: theme.chromeMuted)
        let textColor = Color(nsColor: theme.chromeText)
        let accentColor = Color(nsColor: theme.accentColor)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accentColor)
                Text("BOOKMARKS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(mutedColor)
                    .tracking(0.8)
                if namespace != "local" {
                    Text(namespace)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(accentColor.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(accentColor.opacity(0.1))
                        .cornerRadius(3)
                }

                Spacer()

                Button(action: {
                    onBookmarkCurrent?()
                    refreshBookmarks()
                }) {
                    Image(systemName: isCurrentBookmarked ? "bookmark.slash" : "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(mutedColor)
                }
                .buttonStyle(.plain)
                .help(isCurrentBookmarked ? "Remove bookmark" : "Bookmark current directory")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if bookmarks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bookmark")
                        .font(.system(size: 24))
                        .foregroundStyle(mutedColor.opacity(0.3))
                    Text("No bookmarks yet")
                        .font(fontScale.font(.base))
                        .foregroundStyle(mutedColor.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(bookmarks) { bookmark in
                            BookmarkRow(
                                bookmark: bookmark,
                                isCurrent: bookmark.path == currentDirectory,
                                fontScale: fontScale,
                                textColor: textColor,
                                mutedColor: mutedColor,
                                accentColor: accentColor,
                                onSelect: { onBookmarkSelected?(bookmark.path) },
                                onRemove: {
                                    BookmarkService.shared.remove(id: bookmark.id)
                                    refreshBookmarks()
                                }
                            )
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear { refreshBookmarks() }
    }

    private var isCurrentBookmarked: Bool {
        BookmarkService.shared.contains(path: currentDirectory, namespace: namespace)
    }

    private func refreshBookmarks() {
        bookmarks = BookmarkService.shared.bookmarks(for: namespace)
    }
}

struct BookmarkRow: View {
    let bookmark: BookmarkService.Bookmark
    let isCurrent: Bool
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: bookmark.icon)
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? accentColor : mutedColor.opacity(0.6))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                let nameWeight: Font.Weight = isCurrent ? .semibold : .medium
                Text(bookmark.name)
                    .font(fontScale.font(.base).weight(nameWeight))
                    .foregroundStyle(isCurrent ? accentColor : textColor)
                    .lineLimit(1)

                Text(abbreviatePath(bookmark.path))
                    .font(fontScale.font(.xs))
                    .foregroundStyle(mutedColor.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accentColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? mutedColor.opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Go to bookmark") { onSelect() }
            Divider()
            Button("Remove") { onRemove() }
        }
    }

}
