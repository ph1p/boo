import SwiftUI

// MARK: - Ghostty Theme Gallery

/// Searchable list of the themes Ghostty bundles. Rows parse their theme file
/// lazily as they scroll in, so opening the sheet stays cheap.
struct GhosttyThemeGallery: View {
    @Environment(\.tokens) private var tokens
    /// Names currently picked for a mode; their rows show a checkmark.
    let inUse: Set<String>
    let onSelect: (TerminalTheme) -> Void
    let onClose: () -> Void
    var catalog: GhosttyThemeCatalog = .shared

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var names: [String] {
        let all = catalog.names
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let t = tokens
        let names = names
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: BooStyle.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ghostty Themes").font(.system(size: 15, weight: .semibold)).foregroundStyle(t.text)
                    Spacer()
                    Text("\(names.count) themes").font(BooStyle.Font.caption).foregroundStyle(t.textTertiary)
                }
                TextField("Search themes", text: $query)
                    .themedTextField()
                    .focused($searchFocused)
            }
            .padding(20)

            SettingsRowDivider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        GalleryRow(name: name, catalog: catalog, isInUse: inUse.contains(name), onSelect: onSelect)
                    }
                }
                .padding(.horizontal, BooStyle.Space.md)
                .padding(.vertical, BooStyle.Space.sm)
            }
            .overlay {
                if names.isEmpty {
                    Text(catalog.names.isEmpty ? "No Ghostty themes found." : "No matches.")
                        .font(BooStyle.Font.body)
                        .foregroundStyle(t.textTertiary)
                }
            }

            SettingsRowDivider()
            HStack {
                Text("Click a theme to use it. Its interface colors are generated.")
                    .font(BooStyle.Font.caption)
                    .foregroundStyle(t.textTertiary)
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.themed(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, BooStyle.Space.lg)
        }
        .frame(width: 520, height: 600)
        .background(t.bg)
        .onAppear { searchFocused = true }
    }
}

/// One catalog theme: a strip of its terminal colors, the name and its mode.
private struct GalleryRow: View {
    @Environment(\.tokens) private var tokens
    let name: String
    let catalog: GhosttyThemeCatalog
    let isInUse: Bool
    let onSelect: (TerminalTheme) -> Void
    @State private var hovered = false

    var body: some View {
        let t = tokens
        let theme = catalog.theme(named: name)
        HStack(spacing: BooStyle.Space.md) {
            if let theme {
                swatch(theme)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(t.subtleFill).frame(width: 120, height: 26)
            }
            Text(name)
                .font(.system(size: 12, weight: isInUse ? .semibold : .regular))
                .foregroundStyle(theme == nil ? t.textTertiary : t.text)
                .lineLimit(1)
            Spacer(minLength: BooStyle.Space.sm)
            if let theme {
                Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(t.textTertiary)
                    .help(theme.isDark ? "Dark theme" : "Light theme")
            }
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(t.accent)
                .opacity(isInUse ? 1 : 0)
        }
        .padding(.horizontal, BooStyle.Space.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isInUse ? t.accentSelectionFill : (hovered ? t.hoverFill : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 && theme != nil }
        .onTapGesture { if let theme { onSelect(theme) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Terminal background with a text sample, then the six chromatic ANSI hues.
    private func swatch(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 0) {
            Text("Aa")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.foreground.nsColor))
                .frame(width: 30, height: 26)
                .background(Color(nsColor: theme.background.nsColor))
            ForEach(1..<7, id: \.self) { i in
                Rectangle().fill(Color(nsColor: theme.ansiColors[i].nsColor))
            }
        }
        .frame(width: 120, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tokens.separator, lineWidth: 0.5))
    }
}
