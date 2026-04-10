import SwiftUI

// MARK: - Theme

struct ThemeSettingsView: View {
    @State private var selectedTheme = AppSettings.shared.themeName
    @State private var autoTheme = AppSettings.shared.autoTheme
    @State private var darkTheme = AppSettings.shared.darkThemeName
    @State private var lightTheme = AppSettings.shared.lightThemeName
    @State private var editingTheme: CustomThemeData? = nil
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    private var allThemes: [TerminalTheme] { AppSettings.shared.allThemes }
    private var darkThemes: [TerminalTheme] { allThemes.filter { $0.isDark && !$0.isCustom } }
    private var lightThemes: [TerminalTheme] { allThemes.filter { !$0.isDark && !$0.isCustom } }
    private var customThemes: [TerminalTheme] { allThemes.filter { $0.isCustom } }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Color Theme") {
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
                ToggleRow(label: "Match system dark/light mode", isOn: $autoTheme)
                    .onChange(of: autoTheme) { v in AppSettings.shared.autoTheme = v }
            }

            if autoTheme {
                HStack(spacing: 12) {
                    variantPicker("Dark", icon: "moon.fill", selection: $darkTheme, options: darkThemes)
                        .onChange(of: darkTheme) { v in AppSettings.shared.darkThemeName = v }
                    variantPicker("Light", icon: "sun.max.fill", selection: $lightTheme, options: lightThemes)
                        .onChange(of: lightTheme) { v in AppSettings.shared.lightThemeName = v }
                }
            } else {
                Section(title: "Dark") { themeGrid(darkThemes, tokens: t) }
                Section(title: "Light") { themeGrid(lightThemes, tokens: t) }
            }

            Section(title: "Custom") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(customThemes, id: \.name) { theme in
                        ThemeRow(theme: theme, selectedTheme: $selectedTheme)
                    }
                    Button(action: {
                        editingTheme = CustomThemeData.from(.defaultDark).withName("My Theme")
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                            Text("New Theme…")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(t.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $editingTheme) { theme in
            CustomThemeEditorView(data: theme) { saved in
                var customs = AppSettings.shared.customThemes
                if let idx = customs.firstIndex(where: { $0.name == saved.name }) {
                    customs[idx] = saved
                } else {
                    customs.append(saved)
                }
                AppSettings.shared.customThemes = customs
                selectedTheme = saved.name
                AppSettings.shared.themeName = saved.name
                editingTheme = nil
            } onCancel: {
                editingTheme = nil
            }
        }
    }

    private func variantPicker(
        _ label: String, icon: String, selection: Binding<String>, options: [TerminalTheme]
    ) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9)).foregroundColor(t.muted)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(t.muted)
            }
            Picker("", selection: selection) {
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
        }
    }

    private func themeGrid(_ themes: [TerminalTheme], tokens t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(themes, id: \.name) { ThemeRow(theme: $0, selectedTheme: $selectedTheme) }
        }
    }
}

// MARK: - Theme Row

struct ThemeRow: View {
    let theme: TerminalTheme
    @Binding var selectedTheme: String
    @State private var hovered = false
    @State private var editingTheme: CustomThemeData? = nil

    private var active: Bool { selectedTheme == theme.name }

    private func themeBg() -> Color { tc(theme.background) }
    private func ansi(_ i: Int) -> Color { tc(theme.ansiColors[i]) }
    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var body: some View {
        let t = Tokens.current

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
                .foregroundColor(active ? t.text : t.muted)

            Spacer()

            if theme.isCustom && (hovered || active) {
                HStack(spacing: 2) {
                    iconBtn(systemName: "pencil", color: t.muted) {
                        editingTheme = AppSettings.shared.customThemes.first { $0.name == theme.name }
                    }
                    iconBtn(systemName: "trash", color: t.muted) {
                        var customs = AppSettings.shared.customThemes
                        customs.removeAll { $0.name == theme.name }
                        AppSettings.shared.customThemes = customs
                        if selectedTheme == theme.name {
                            selectedTheme = "Default Dark"
                            AppSettings.shared.themeName = "Default Dark"
                        }
                    }
                }
            }

            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(t.accent)
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
        .sheet(item: $editingTheme) { theme in
            CustomThemeEditorView(data: theme) { saved in
                var customs = AppSettings.shared.customThemes
                if let idx = customs.firstIndex(where: { $0.name == saved.name }) {
                    customs[idx] = saved
                } else {
                    customs.append(saved)
                }
                AppSettings.shared.customThemes = customs
                selectedTheme = saved.name
                AppSettings.shared.themeName = saved.name
                editingTheme = nil
            } onCancel: {
                editingTheme = nil
            }
        }
    }

    private func iconBtn(systemName: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .frame(width: 20, height: 20)
                .foregroundColor(color)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
