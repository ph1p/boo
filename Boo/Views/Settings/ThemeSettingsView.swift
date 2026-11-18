import AppKit
import SwiftUI

// MARK: - Theme

struct ThemeSettingsView: View {
    @Environment(\.tokens) private var tokens
    @State private var selectedTheme = AppSettings.shared.themeName
    @State private var autoTheme = AppSettings.shared.autoTheme
    @State private var darkTheme = AppSettings.shared.darkThemeName
    @State private var lightTheme = AppSettings.shared.lightThemeName
    @State private var editingTheme: CustomThemeData? = nil
    /// Name of the custom theme being edited; nil when the editor creates a new one.
    @State private var editingOriginalName: String? = nil
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])
    @State private var showingGallery = false

    /// Ghostty catalog themes currently picked for a mode, shown as cards so
    /// the selection stays visible outside the gallery.
    private var ghosttyInUse: [TerminalTheme] {
        let names = autoTheme ? [darkTheme, lightTheme] : [selectedTheme]
        let curated = Set(TerminalTheme.themes.map(\.name))
        let customs = Set(AppSettings.shared.customThemes.map(\.name))
        var seen = Set<String>()
        return names.compactMap { name in
            guard !curated.contains(name), !customs.contains(name), seen.insert(name).inserted else { return nil }
            return GhosttyThemeCatalog.shared.theme(named: name)
        }
    }

    private var customThemes: [TerminalTheme] { AppSettings.shared.customThemes.map { $0.toTheme() } }
    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    var body: some View {
        let _ = observer.revision

        SettingsPage(title: "Theme") {
            Section(title: "Appearance Mode") {
                ToggleRow(
                    label: "Match system dark/light mode",
                    help: "Follow the system setting. Click a card to use it for its mode.",
                    isOn: $autoTheme
                )
                .onChange(of: autoTheme) { _, v in AppSettings.shared.autoTheme = v }
                SettingRow(
                    label: "Interface contrast",
                    help: "How far the sidebar, toolbar and borders step away from the terminal background."
                ) {
                    ThemedSegmentedPicker(selection: SettingsBindings.binding(\.chromeContrast)) { $0.label }
                }
            }

            Section(
                title: "Themes", footer: autoTheme ? "The moon and sun mark the themes used in each mode." : nil,
                dividers: false
            ) {
                // Declared order: each family's dark variant, then its light one,
                // so the two-column grid shows one family per row.
                themeGrid(TerminalTheme.themes)
            }

            Section(
                title: "Ghostty Themes",
                footer: "\(GhosttyThemeCatalog.shared.names.count) more themes bundled with Ghostty.",
                dividers: false
            ) {
                let inUse = ghosttyInUse
                if !inUse.isEmpty { themeGrid(inUse) }
                HStack(spacing: 8) {
                    actionButton("Browse Themes…", icon: "square.grid.2x2") { showingGallery = true }
                    Spacer(minLength: 0)
                }
            }

            Section(title: "Custom", dividers: false) {
                let customs = customThemes
                if !customs.isEmpty { themeGrid(customs) }
                HStack(spacing: 8) {
                    actionButton("New Theme…", icon: "plus") {
                        // Seed the editor with the colors currently in use, so a
                        // new theme starts as a tweak of what's on screen.
                        editingOriginalName = nil
                        editingTheme = CustomThemeData.from(AppSettings.shared.theme)
                            .withName(AppSettings.shared.uniqueThemeName("My Theme"))
                    }
                    actionButton("Import Theme…", icon: "square.and.arrow.down", action: importTheme)
                        .help("Import an iTerm2 .itermcolors file or a Ghostty theme file")
                    Spacer(minLength: 0)
                }
            }

            Section(title: "App Icon", footer: "Changes the Dock icon while Boo runs. Finder keeps the default.") {
                AppIconPicker()
            }
        }
        .sheet(isPresented: $showingGallery) {
            GhosttyThemeGallery(inUse: Set([selectedTheme, darkTheme, lightTheme])) { theme in
                select(theme)
            } onClose: {
                showingGallery = false
            }
        }
        .sheet(item: $editingTheme) { theme in
            CustomThemeEditorView(data: theme) { saved in
                let name = AppSettings.shared.saveCustomTheme(saved, replacing: editingOriginalName)
                if editingOriginalName == nil || editingOriginalName == selectedTheme { selectedTheme = name }
                editingTheme = nil
            } onCancel: {
                editingTheme = nil
            }
        }
    }

    private func themeGrid(_ themes: [TerminalTheme]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(themes, id: \.name) { theme in
                ThemeCard(
                    theme: theme,
                    isSelected: !autoTheme && selectedTheme == theme.name,
                    modeBadges: autoTheme ? badges(for: theme) : [],
                    onSelect: { select(theme) },
                    onEdit: theme.isCustom ? { edit(theme) } : nil,
                    onDelete: theme.isCustom ? { delete(theme) } : nil
                )
            }
        }
    }

    private func badges(for theme: TerminalTheme) -> [String] {
        var icons: [String] = []
        if theme.name == darkTheme { icons.append("moon.fill") }
        if theme.name == lightTheme { icons.append("sun.max.fill") }
        return icons
    }

    /// Manual mode switches the theme; auto mode assigns the card to the mode
    /// that matches its background.
    private func select(_ theme: TerminalTheme) {
        if autoTheme {
            if theme.isDark {
                darkTheme = theme.name
                AppSettings.shared.darkThemeName = theme.name
            } else {
                lightTheme = theme.name
                AppSettings.shared.lightThemeName = theme.name
            }
        } else {
            selectedTheme = theme.name
            AppSettings.shared.themeName = theme.name
        }
    }

    private func edit(_ theme: TerminalTheme) {
        guard let data = AppSettings.shared.customThemes.first(where: { $0.name == theme.name }) else { return }
        editingOriginalName = theme.name
        editingTheme = data
    }

    private func delete(_ theme: TerminalTheme) {
        var customs = AppSettings.shared.customThemes
        customs.removeAll { $0.name == theme.name }
        AppSettings.shared.customThemes = customs
        if selectedTheme == theme.name {
            selectedTheme = "Boo Dark"
            AppSettings.shared.themeName = "Boo Dark"
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.themed(.primary, size: .large))
    }

    /// Pick a color scheme file and open it in the editor, so the derived
    /// chrome colors can be reviewed before the theme is saved.
    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an iTerm2 (.itermcolors) or Ghostty theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ThemeImporter.importTheme(at: url)
            editingOriginalName = nil
            editingTheme = imported.withName(AppSettings.shared.uniqueThemeName(imported.name))
        } catch {
            BooAlert.showError(title: "Cannot Import Theme", message: error.localizedDescription)
        }
    }
}

// MARK: - Theme Card

/// A selectable theme tile: a miniature Boo window painted in the theme's own
/// colors (backdrop, sidebar island, terminal pane, accent), so the 60-30-10
/// split is visible before the theme is applied.
struct ThemeCard: View {
    @Environment(\.tokens) private var tokens
    let theme: TerminalTheme
    let isSelected: Bool
    /// SF Symbols for the auto modes this theme is assigned to (moon, sun).
    var modeBadges: [String] = []
    let onSelect: () -> Void
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var hovered = false
    @State private var confirmingDelete = false

    private var highlighted: Bool { isSelected || !modeBadges.isEmpty }

    var body: some View {
        let t = tokens
        VStack(alignment: .leading, spacing: 7) {
            ThemePreview(theme: theme)
                .frame(height: 74)
            HStack(spacing: 5) {
                Text(theme.name)
                    .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? t.text : t.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                ForEach(modeBadges, id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(t.accent)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
            }
            .padding(.horizontal, 2)
            if onEdit != nil || onDelete != nil { cardActions }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? t.accentSelectionFill : (hovered ? t.hoverFill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlighted ? t.focusRing : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if let onEdit { Button("Edit…", action: onEdit) }
            if onDelete != nil { Button("Delete…", role: .destructive) { confirmingDelete = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityActions {
            if let onEdit { Button("Edit", action: onEdit) }
            if onDelete != nil { Button("Delete") { confirmingDelete = true } }
        }
        .confirmationDialog("Delete \"\(theme.name)\"?", isPresented: $confirmingDelete) {
            Button("Delete Theme", role: .destructive) { onDelete?() }
        } message: {
            Text("This custom theme is removed for good.")
        }
    }

    /// Edit and delete for custom themes, always visible so they are easy to
    /// find and hit. The context menu offers the same two actions.
    private var cardActions: some View {
        HStack(spacing: BooStyle.Space.sm) {
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.themed(.secondary, fullWidth: true))
                .help("Edit theme colors")
            }
            if onDelete != nil {
                Button(action: { confirmingDelete = true }) {
                    Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                        .frame(width: 14)
                }
                .buttonStyle(.themed(.destructive))
                .help("Delete theme")
                .accessibilityLabel("Delete theme")
            }
        }
    }
}

/// Miniature window: the backdrop frame, a sidebar island with a selected row,
/// and a terminal pane with a colored prompt and the theme's cursor.
struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        let p = Tokens(theme: theme)
        let ansi: (Int) -> Color = { Color(nsColor: theme.ansiColors[$0].nsColor) }
        let island = RoundedRectangle(cornerRadius: 4, style: .continuous)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(p.textTertiary).frame(width: 4, height: 4) }
            }
            .padding(.leading, 2)
            HStack(spacing: 3) { islands(p, ansi: ansi, island: island) }
        }
        .padding(4)
        .background(p.backdrop, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.border, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func islands(
        _ p: Tokens, ansi: (Int) -> Color, island: RoundedRectangle
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(p.accentSelectionFill)
                .overlay(alignment: .leading) {
                    Capsule().fill(p.accent).frame(width: 14, height: 3).padding(.leading, 3)
                }
                .frame(height: 8)
            ForEach([18, 12, 16], id: \.self) { w in
                Capsule().fill(p.textTertiary).frame(width: CGFloat(w), height: 3).padding(.leading, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: 40, maxHeight: .infinity, alignment: .topLeading)
        .background(p.bg, in: island)
        .overlay(island.strokeBorder(p.border, lineWidth: 0.5))

        VStack(alignment: .leading, spacing: 5) {
            bars([(ansi(2), 6), (p.fg, 26), (ansi(4), 14)])
            bars([(ansi(5), 12), (ansi(3), 18)])
            bars([(ansi(1), 10), (p.fg.opacity(0.6), 22)])
            HStack(spacing: 3) {
                Capsule().fill(p.accent).frame(width: 6, height: 3)
                Rectangle().fill(Color(nsColor: theme.cursor.nsColor)).frame(width: 4, height: 7)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.termBg, in: island)
        .overlay(island.strokeBorder(p.color(\.borderPane), lineWidth: 0.5))
    }

    private func bars(_ items: [(Color, CGFloat)]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Capsule().fill(item.0).frame(width: item.1, height: 3)
            }
        }
    }
}

// MARK: - Theme Row

struct ThemeRow: View {
    @Environment(\.tokens) private var tokens
    let theme: TerminalTheme
    @Binding var selectedTheme: String
    @State private var hovered = false

    private var active: Bool { selectedTheme == theme.name }

    private func themeBg() -> Color { tc(theme.background) }
    private func ansi(_ i: Int) -> Color { tc(theme.ansiColors[i]) }
    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var body: some View {
        let t = tokens

        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Rectangle().fill(themeBg()).frame(width: 10)
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in Rectangle().fill(ansi(i)) }
            }
            .frame(width: 52, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(t.muted.opacity(0.15), lineWidth: 0.5))

            Text(theme.name)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? t.text : t.muted)

            Spacer()

            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(t.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? t.accent.opacity(0.08) : (hovered ? t.muted.opacity(0.06) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? t.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            selectedTheme = theme.name
            AppSettings.shared.themeName = theme.name
        }
    }
}

// MARK: - App Icon

/// Tiles for `AppSettings.appIcon`.
struct AppIconPicker: View {
    @Environment(\.tokens) private var tokens
    @State private var selected = AppSettings.shared.appIcon
    private let images = Dictionary(uniqueKeysWithValues: AppIconStyle.allCases.map { ($0, $0.image) })

    var body: some View {
        let t = tokens
        HStack(spacing: 12) {
            ForEach(AppIconStyle.allCases, id: \.self) { style in
                let active = selected == style
                VStack(spacing: 4) {
                    Group {
                        if let image = images[style] ?? nil {
                            Image(nsImage: image).resizable()
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(t.muted)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(active ? t.accent.opacity(0.08) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(active ? t.accent.opacity(0.6) : t.muted.opacity(0.15), lineWidth: 1)
                            )
                    )
                    Text(style.label)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? t.text : t.muted)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selected = style
                    AppSettings.shared.appIcon = style
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(style.label) app icon")
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
