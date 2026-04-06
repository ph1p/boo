import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design Tokens

/// Single source of truth for settings UI styling.
/// Every sub-view pulls from here instead of re-deriving colors inline.
private struct Tokens {
    let theme: TerminalTheme
    var text: Color { Color(nsColor: theme.chromeText) }
    var muted: Color { Color(nsColor: theme.chromeMuted) }
    var accent: Color { Color(nsColor: theme.accentColor) }
    var bg: Color { Color(nsColor: theme.sidebarBg) }
    var chromeBg: Color { Color(nsColor: theme.chromeBg) }
    var border: Color { Color(nsColor: theme.sidebarBorder) }
    var fg: Color {
        Color(
            red: Double(theme.foreground.r) / 255,
            green: Double(theme.foreground.g) / 255,
            blue: Double(theme.foreground.b) / 255)
    }
    var termBg: Color {
        Color(
            red: Double(theme.background.r) / 255,
            green: Double(theme.background.g) / 255,
            blue: Double(theme.background.b) / 255)
    }

    static var current: Tokens { Tokens(theme: AppSettings.shared.theme) }
}

// MARK: - Root

struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general = "General"
        case theme = "Theme"
        case appearance = "Appearance"
        case statusBar = "Status Bar"
        case layout = "Layout"
        case plugins = "Plugins"
        case shortcuts = "Shortcuts"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .theme: return "paintpalette"
            case .appearance: return "textformat"
            case .statusBar: return "rectangle.bottomthird.inset.filled"
            case .layout: return "rectangle.3.group"
            case .plugins: return "puzzlepiece"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selectedTab: Tab = .general
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        VStack(spacing: 0) {
            // Custom title bar extending under the transparent native title bar
            titleBar(t)

            HStack(spacing: 0) {
                sidebar(t)

                Rectangle()
                    .fill(t.border)
                    .frame(width: 0.5)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 500)
        .background(t.bg)
    }

    // MARK: Title Bar

    private func titleBar(_ t: Tokens) -> some View {
        ZStack {
            t.chromeBg
            Text("Settings")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(t.muted)
                .offset(y: -1)
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(t.border)
                    .frame(height: 0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    // MARK: Sidebar

    private func sidebar(_ t: Tokens) -> some View {
        VStack(spacing: 1) {
            ForEach(Tab.allCases, id: \.self) { tab in
                HStack(spacing: 8) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))
                        .frame(width: 18)
                    Text(tab.rawValue)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundColor(selectedTab == tab ? t.text : t.muted)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedTab == tab ? t.accent.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedTab = tab }
            }
            Spacer()
        }
        .padding(10)
        .fixedSize(horizontal: true, vertical: false)
        .background(t.chromeBg)
    }

    // MARK: Content Router

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general: GeneralSettingsView()
        case .theme: ThemeSettingsView()
        case .appearance: AppearanceSettingsView()
        case .statusBar: StatusBarSettingsView()
        case .layout: LayoutSettingsView()
        case .plugins: PluginSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        }
    }
}

// MARK: - Settings Page Shell

/// Every tab uses this wrapper so layout is identical: title, scroll, consistent padding.
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let t = Tokens.current
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(t.text)
                    Rectangle()
                        .fill(t.border.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 0.5)
                }
                content()
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

}

/// Labeled group within a page — renders a header label above a card-style container.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(t.muted)
                .tracking(0.4)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(t.chromeBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(t.border.opacity(0.6), lineWidth: 0.5)
                    )
            )
        }
    }

}

// MARK: - Reusable Controls

private struct FontSizePicker: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .push
        popup.controlSize = .regular
        let sizes = Array(stride(from: range.lowerBound, through: range.upperBound, by: 1))
        for size in sizes {
            popup.addItem(withTitle: "\(Int(size)) pt")
            popup.lastItem?.tag = Int(size)
        }
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        let tag = Int(value)
        if popup.selectedTag() != tag {
            popup.selectItem(withTag: tag)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            value.wrappedValue = Double(sender.selectedTag())
        }
    }
}

private struct FontChooser: NSViewRepresentable {
    @Binding var selectedFont: String
    let fonts: [String]

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .push
        popup.controlSize = .regular
        for name in fonts {
            popup.addItem(withTitle: name)
            guard let item = popup.lastItem else { continue }
            item.attributedTitle = NSAttributedString(
                string: name,
                attributes: [.font: NSFont(name: name, size: 13) ?? NSFont.systemFont(ofSize: 13)]
            )
        }
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        if popup.titleOfSelectedItem != selectedFont {
            popup.selectItem(withTitle: selectedFont)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selectedFont: $selectedFont) }

    final class Coordinator: NSObject {
        var selectedFont: Binding<String>
        init(selectedFont: Binding<String>) { self.selectedFont = selectedFont }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let title = sender.titleOfSelectedItem {
                selectedFont.wrappedValue = title
            }
        }
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        let t = Tokens.current
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

}

// MARK: - Theme

private struct ThemeSettingsView: View {
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

    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

private struct ThemeRow: View {
    let theme: TerminalTheme
    @Binding var selectedTheme: String
    @State private var hovered = false
    @State private var editingTheme: CustomThemeData? = nil

    private var active: Bool { selectedTheme == theme.name }

    // Stripes use the row theme's own colors
    private func themeBg() -> Color { tc(theme.background) }
    private func ansi(_ i: Int) -> Color { tc(theme.ansiColors[i]) }
    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var body: some View {
        // UI chrome comes from the active app theme (Tokens), not the row's theme
        let t = Tokens.current

        HStack(spacing: 8) {
            // Stripes: this theme's bg + 6 ANSI colors
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

// MARK: - Custom Theme Editor

private struct CustomThemeEditorView: View {
    @State var data: CustomThemeData
    let onSave: (CustomThemeData) -> Void
    let onCancel: () -> Void

    private var preview: TerminalTheme { data.toTheme() }
    private let ansiLabels = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    var body: some View {
        let t = Tokens.current
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 12) {
                TextField("Theme name", text: $data.name)
                    .font(.system(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                    .foregroundColor(t.text)
                Spacer()
                // Live color strip preview
                HStack(spacing: 0) {
                    Rectangle().fill(tc(preview.background)).frame(width: 18)
                    ForEach(0..<8, id: \.self) { i in Rectangle().fill(tc(preview.ansiColors[i])) }
                    ForEach(8..<16, id: \.self) { i in Rectangle().fill(tc(preview.ansiColors[i])) }
                }
                .frame(width: 136, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.muted.opacity(0.15), lineWidth: 0.5))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.25)

            // ── Body ─────────────────────────────────────────────────────────
            ScrollView {
                HStack(alignment: .top, spacing: 0) {

                    // Left column: Terminal + ANSI
                    VStack(alignment: .leading, spacing: 20) {
                        EditorSection(title: "Terminal") {
                            SwatchRow(label: "Foreground", hex: hexBinding(\.foreground))
                            SwatchRow(label: "Background", hex: hexBinding(\.background))
                            SwatchRow(label: "Cursor", hex: hexBinding(\.cursor))
                            SwatchRow(label: "Selection", hex: $data.selectionHex)
                        }

                        EditorSection(title: "ANSI — Normal") {
                            ForEach(0..<8, id: \.self) { i in
                                SwatchRow(label: ansiLabels[i], hex: ansiBinding(i))
                            }
                        }

                        EditorSection(title: "ANSI — Bright") {
                            ForEach(0..<8, id: \.self) { i in
                                SwatchRow(label: ansiLabels[i], hex: ansiBinding(i + 8))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)

                    // Divider between columns
                    Rectangle()
                        .fill(t.muted.opacity(0.15))
                        .frame(width: 0.5)
                        .padding(.vertical, 4)

                    // Right column: UI Chrome
                    VStack(alignment: .leading, spacing: 20) {
                        EditorSection(title: "UI Chrome") {
                            SwatchRow(label: "Toolbar BG", hex: $data.chromeBgHex)
                            SwatchRow(label: "Toolbar Text", hex: $data.chromeTextHex)
                            SwatchRow(label: "Muted Text", hex: $data.chromeMutedHex)
                            SwatchRow(label: "Sidebar BG", hex: $data.sidebarBgHex)
                            SwatchRow(label: "Accent", hex: $data.accentHex)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                }
                .padding(20)
            }

            Divider().opacity(0.25)

            // ── Footer ───────────────────────────────────────────────────────
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    while data.ansiColors.count < 16 {
                        data.ansiColors.append(TerminalColor(r: 128, g: 128, b: 128))
                    }
                    onSave(data)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(data.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 540)
        .background(t.bg)
    }

    // MARK: Bindings

    private func hexBinding(_ kp: WritableKeyPath<CustomThemeData, TerminalColor>) -> Binding<String> {
        Binding(
            get: { data[keyPath: kp].hexString },
            set: { if let c = TerminalColor(hex: $0) { data[keyPath: kp] = c } }
        )
    }

    private func ansiBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < data.ansiColors.count ? data.ansiColors[index].hexString : "#808080" },
            set: { hex in
                guard let c = TerminalColor(hex: hex) else { return }
                while data.ansiColors.count <= index { data.ansiColors.append(TerminalColor(r: 128, g: 128, b: 128)) }
                data.ansiColors[index] = c
            }
        )
    }

    private func tc(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

// ── Editor building blocks ──────────────────────────────────────────────────

private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(t.muted)
                .tracking(0.6)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }
}

/// One row: color well + label + editable hex field.
private struct SwatchRow: View {
    let label: String
    @Binding var hex: String

    // Draft text while typing — lets user type freely before committing
    @State private var draft: String = ""
    @State private var isEditing = false
    @State private var isInvalid = false

    private var isValid: Bool { TerminalColor(hex: draft) != nil }

    var body: some View {
        let t = Tokens.current
        HStack(spacing: 8) {
            // Color well
            ColorWell(hex: $hex)
                .frame(width: 26, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.muted.opacity(0.15), lineWidth: 0.5))

            // Label
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(t.muted)
                .frame(width: 88, alignment: .leading)

            // Editable hex field
            TextField("", text: $draft)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isInvalid ? Color.red.opacity(0.8) : t.muted.opacity(0.75))
                .frame(width: 64)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEditing ? t.muted.opacity(0.08) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    isInvalid
                                        ? Color.red.opacity(0.5)
                                        : (isEditing ? t.accent.opacity(0.4) : Color.clear),
                                    lineWidth: 1
                                )
                        )
                )
                .onAppear { draft = hex.uppercased() }
                .onChange(of: hex) { newHex in
                    if !isEditing { draft = newHex.uppercased() }
                }
                .onSubmit { commitDraft() }
                .onChange(of: draft) { _ in
                    isInvalid = !draft.isEmpty && TerminalColor(hex: draft) == nil
                }
                .onTapGesture { isEditing = true }
                .onExitCommand {
                    isEditing = false
                    draft = hex.uppercased()
                    isInvalid = false
                }
        }
        .onChange(of: isEditing) { editing in
            if !editing { commitDraft() }
        }
    }

    private func commitDraft() {
        if let c = TerminalColor(hex: draft) {
            hex = c.hexString.uppercased()
            isInvalid = false
        } else {
            // Revert to last valid value
            draft = hex.uppercased()
            isInvalid = false
        }
        isEditing = false
    }
}

/// NSColorWell bridge that binds to a hex string.
private struct ColorWell: NSViewRepresentable {
    @Binding var hex: String

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = NSColor(hex: hex) ?? .gray
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        if let c = NSColor(hex: hex), c.usingColorSpace(.sRGB) != well.color.usingColorSpace(.sRGB) {
            well.color = c
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    final class Coordinator: NSObject {
        var hex: Binding<String>
        init(hex: Binding<String>) { self.hex = hex }
        @objc func colorChanged(_ sender: NSColorWell) {
            guard let c = sender.color.usingColorSpace(.sRGB) else { return }
            hex.wrappedValue = String(
                format: "#%02X%02X%02X",
                Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)
            )
        }
    }
}

// MARK: - Helpers

extension TerminalColor {
    fileprivate var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    fileprivate init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
}

extension CustomThemeData {
    fileprivate func withName(_ newName: String) -> CustomThemeData {
        var copy = self
        copy.name = newName
        return copy
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var defaultFolder = AppSettings.shared.defaultFolder
    @State private var autoCheckUpdates = AppSettings.shared.autoCheckUpdates
    @State private var debugLogging = AppSettings.shared.debugLogging
    @State private var fileEditorCommand = AppSettings.shared.fileEditorCommand
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "General") {
            Section(title: "Default Folder") {
                HStack(spacing: 8) {
                    Text(defaultFolder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(t.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
                        panel.message = "Choose the default folder for new workspaces"
                        if panel.runModal() == .OK, let url = panel.url {
                            defaultFolder = url.path
                            AppSettings.shared.defaultFolder = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reset") {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        defaultFolder = home
                        AppSettings.shared.defaultFolder = home
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Section(title: "File Editor") {
                HStack(spacing: 8) {
                    TextField("vim, nvim, nano… (empty = $EDITOR)", text: $fileEditorCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )
                        .onSubmit {
                            AppSettings.shared.fileEditorCommand =
                                fileEditorCommand.trimmingCharacters(in: .whitespaces)
                        }
                        .onChange(of: fileEditorCommand) { v in
                            AppSettings.shared.fileEditorCommand =
                                v.trimmingCharacters(in: .whitespaces)
                        }
                }
                Text("Command run when clicking a file in the explorer. Leave empty to use $EDITOR.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Updates") {
                ToggleRow(label: "Check for updates automatically", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { v in AppSettings.shared.autoCheckUpdates = v }
            }

            Section(title: "Advanced") {
                ToggleRow(label: "Debug logging", isOn: $debugLogging)
                    .onChange(of: debugLogging) { v in AppSettings.shared.debugLogging = v }
                Text("Writes verbose output to the system log. Disable when not troubleshooting.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }
        }
        .foregroundColor(t.text)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @State private var cursorStyle = AppSettings.shared.cursorStyle
    @State private var termFontSize = Double(AppSettings.shared.fontSize)
    @State private var termSelectedFont = AppSettings.shared.fontName
    @State private var sidebarFontSize = Double(AppSettings.shared.sidebarFontSize)
    @State private var sidebarSelectedFont =
        AppSettings.shared.sidebarFontName.isEmpty ? "System Default" : AppSettings.shared.sidebarFontName
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .terminal, .sidebarFont])

    private let monoFonts = AppSettings.availableMonospaceFonts
    private let systemFonts = AppSettings.availableSystemFonts

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Appearance") {
            Section(title: "Cursor") {
                Picker("", selection: $cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: cursorStyle) { v in AppSettings.shared.cursorStyle = v }
            }

            Section(title: "Terminal Font") {
                FontChooser(selectedFont: $termSelectedFont, fonts: monoFonts)
                    .onChange(of: termSelectedFont) { v in AppSettings.shared.fontName = v }
                FontSizePicker(value: $termFontSize, range: 10...28)
                    .onChange(of: termFontSize) { v in AppSettings.shared.fontSize = CGFloat(v) }
                Text("$ echo \"Hello, Boo\"")
                    .font(.custom(termSelectedFont, size: CGFloat(termFontSize)))
                    .foregroundColor(t.fg)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.termBg))
            }

            Section(title: "Sidebar Font") {
                FontChooser(selectedFont: $sidebarSelectedFont, fonts: systemFonts)
                    .onChange(of: sidebarSelectedFont) { v in
                        AppSettings.shared.sidebarFontName = v == "System Default" ? "" : v
                    }
                FontSizePicker(value: $sidebarFontSize, range: 10...20)
                    .onChange(of: sidebarFontSize) { v in AppSettings.shared.sidebarFontSize = CGFloat(v) }
                Text("Applied to file trees and content only — not to section headers.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Section Header")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(t.muted)
                    let previewFont: Font = {
                        let name = sidebarSelectedFont == "System Default" ? "" : sidebarSelectedFont
                        if name.isEmpty { return .system(size: CGFloat(sidebarFontSize)) }
                        return .custom(name, size: CGFloat(sidebarFontSize))
                    }()
                    Text("  Documents")
                        .font(previewFont)
                        .foregroundColor(t.text)
                    Text("  Projects")
                        .font(previewFont)
                        .foregroundColor(t.text)
                    Text("  README.md")
                        .font(previewFont)
                        .foregroundColor(t.muted)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.chromeBg))
            }
        }
        .foregroundColor(t.text)
    }
}

// MARK: - Status Bar

private struct StatusBarSettingsView: View {
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showConnection = AppSettings.shared.statusBarShowConnection
    @State private var showPath = AppSettings.shared.statusBarShowPath
    @State private var showGitBranch = AppSettings.shared.statusBarShowGitBranch
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        SettingsPage(title: "Status Bar") {
            Section(title: "Preview") {
                statusBarPreview(t)
            }

            Section(title: "Left Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Connection", isOn: $showConnection)
                        .onChange(of: showConnection) { v in AppSettings.shared.statusBarShowConnection = v }
                    ToggleRow(label: "Current path", isOn: $showPath)
                        .onChange(of: showPath) { v in AppSettings.shared.statusBarShowPath = v }
                    ToggleRow(label: "Git branch", isOn: $showGitBranch)
                        .onChange(of: showGitBranch) { v in AppSettings.shared.statusBarShowGitBranch = v }
                }
            }

            Section(title: "Right Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Pane & tab count", isOn: $showPaneInfo)
                        .onChange(of: showPaneInfo) { v in AppSettings.shared.statusBarShowPaneInfo = v }
                    ToggleRow(label: "Clock", isOn: $showTime)
                        .onChange(of: showTime) { v in AppSettings.shared.statusBarShowTime = v }
                }
            }
        }
    }

    private func statusBarPreview(_ t: Tokens) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if showConnection {
                    statusChip(icon: "circle.fill", label: "local", color: Color.green, t: t)
                }
                if showPath {
                    statusChip(icon: "folder", label: "~/projects/boo", color: t.muted, t: t)
                }
                if showGitBranch {
                    statusChip(icon: "arrow.triangle.branch", label: "main", color: t.muted, t: t)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if showPaneInfo {
                    statusChip(icon: nil, label: "2 panes \u{00B7} 3 tabs", color: t.muted, t: t)
                }
                if showTime {
                    statusChip(icon: nil, label: "12:00", color: t.muted, t: t)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(t.chromeBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(t.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func statusChip(icon: String?, label: String, color: Color, t: Tokens) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(color)
        }
    }

}

// MARK: - Layout

struct LayoutSettingsView: View {
    @State private var sidebarPosition = AppSettings.shared.sidebarPosition
    @State private var sidebarDefaultHidden = AppSettings.shared.sidebarDefaultHidden
    @State private var workspaceBarPosition = AppSettings.shared.workspaceBarPosition
    @State private var tabOverflowMode = AppSettings.shared.tabOverflowMode
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .layout])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar") {
                Picker("Position", selection: $sidebarPosition) {
                    ForEach(SidebarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sidebarPosition) { v in AppSettings.shared.sidebarPosition = v }

                ToggleRow(label: "Hide sidebar by default", isOn: $sidebarDefaultHidden)
                    .onChange(of: sidebarDefaultHidden) { v in AppSettings.shared.sidebarDefaultHidden = v }
                Text("Toggle the sidebar with \u{2318}B.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Workspace Bar") {
                Picker("", selection: $workspaceBarPosition) {
                    ForEach(WorkspaceBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: workspaceBarPosition) { v in AppSettings.shared.workspaceBarPosition = v }
                Text("Position of the workspace switcher bar.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

            Section(title: "Tab Overflow") {
                Picker("", selection: $tabOverflowMode) {
                    ForEach(TabOverflowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tabOverflowMode) { v in AppSettings.shared.tabOverflowMode = v }
                Text("How tabs behave when they exceed the available bar width.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }

        }
        .foregroundColor(t.text)
    }

}

// MARK: - Plugins

struct PluginSettingsView: View {
    /// Set by MainWindowController before showing settings.
    static var registeredManifests: [PluginManifest] = []

    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        let manifests = Self.registeredManifests

        SettingsPage(title: "Plugins") {
            Text("Built-in plugins provide core functionality. External plugins are loaded from ~/.boo/plugins/")
                .font(.system(size: 11))
                .foregroundColor(t.muted)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(manifests, id: \.id) { manifest in
                    PluginRow(manifest: manifest)
                }
            }

            Section(title: "Default Sidebar Plugins") {
                Text("Plugins shown in the sidebar when opening a new pane. Drag or use arrows to reorder.")
                    .font(.system(size: 10))
                    .foregroundColor(t.muted)
                DefaultPluginOrderView(manifests: manifests.filter { $0.capabilities?.sidebarPanel == true })
            }
        }
    }

}

private struct PluginRow: View {
    let manifest: PluginManifest

    @State private var isEnabled: Bool
    @State private var isExpanded: Bool = false
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    init(manifest: PluginManifest) {
        self.manifest = manifest
        self._isEnabled = State(initialValue: !AppSettings.shared.disabledPluginIDs.contains(manifest.id))
    }

    /// Returns true when at least one of the plugin's settings deviates from its declared default.
    private var hasCustomSettings: Bool {
        guard let settings = manifest.settings else { return false }
        for s in settings {
            switch s.type {
            case .bool:
                let def = s.defaultValue?.value as? Bool ?? false
                if AppSettings.shared.pluginBool(manifest.id, s.key, default: def) != def { return true }
            case .double:
                let def = s.defaultValue?.value as? Double ?? 0
                if AppSettings.shared.pluginDouble(manifest.id, s.key, default: def) != def { return true }
            case .string:
                let def = s.defaultValue?.value as? String ?? ""
                if AppSettings.shared.pluginString(manifest.id, s.key, default: def) != def { return true }
            case .int:
                break
            }
        }
        return false
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: manifest.icon)
                    .font(.system(size: 14))
                    .foregroundColor(isEnabled ? t.text : t.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(manifest.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isEnabled ? t.text : t.muted)
                        Text(manifest.isExternal ? "External" : "Built-in")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(t.muted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(t.muted.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(manifest.description ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(t.muted)
                }
                Spacer()

                if let settings = manifest.settings, !settings.isEmpty {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(t.muted)
                            if hasCustomSettings && !isExpanded {
                                Circle()
                                    .fill(t.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 4, y: -3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isEnabled) { enabled in
                        var disabled = AppSettings.shared.disabledPluginIDs
                        if enabled {
                            disabled.removeAll { $0 == manifest.id }
                        } else {
                            disabled.append(manifest.id)
                        }
                        AppSettings.shared.disabledPluginIDs = disabled
                    }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            if isExpanded, let settings = manifest.settings, !settings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings, id: \.key) { setting in
                        PluginSettingControl(pluginID: manifest.id, setting: setting)
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .accessibilityLabel("\(manifest.name), \(isEnabled ? "enabled" : "disabled"), \(manifest.description ?? "")")
    }

}

/// Reorderable list of default sidebar plugins with toggle, drag-and-drop, and arrow buttons.
private struct DefaultPluginOrderView: View {
    let manifests: [PluginManifest]
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])
    @State private var orderedIDs: [String] = []
    @State private var draggedID: String?

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        let disabledSet = AppSettings.shared.disabledPluginIDsSet
        let visibleIDs = orderedIDs.filter { !disabledSet.contains($0) }
        let enabledSet = Set(AppSettings.shared.defaultEnabledPluginIDs)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(visibleIDs.enumerated()), id: \.element) { index, pluginID in
                if let manifest = manifests.first(where: { $0.id == pluginID }) {
                    let isEnabled = enabledSet.contains(pluginID)
                    let realIndex = orderedIDs.firstIndex(of: pluginID) ?? index
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundColor(t.muted.opacity(0.5))
                            .frame(width: 12)

                        Image(systemName: manifest.icon)
                            .font(.system(size: 12))
                            .foregroundColor(isEnabled ? t.text : t.muted)
                            .frame(width: 16)

                        Text(manifest.name)
                            .font(.system(size: 12))
                            .foregroundColor(isEnabled ? t.text : t.muted)

                        Spacer()

                        Button(action: { moveUp(realIndex) }) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(index > 0 ? t.text : t.muted.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)

                        Button(action: { moveDown(realIndex) }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(index < visibleIDs.count - 1 ? t.text : t.muted.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(index >= visibleIDs.count - 1)

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { enabledSet.contains(pluginID) },
                                set: { enabled in
                                    var list = AppSettings.shared.defaultEnabledPluginIDs
                                    if enabled {
                                        if !list.contains(pluginID) { list.append(pluginID) }
                                    } else {
                                        list.removeAll { $0 == pluginID }
                                    }
                                    AppSettings.shared.defaultEnabledPluginIDs = list
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(draggedID == pluginID ? t.accent.opacity(0.1) : t.muted.opacity(0.05))
                    )
                    .opacity(draggedID == pluginID ? 0.6 : 1.0)
                    .onDrag {
                        draggedID = pluginID
                        return NSItemProvider(object: pluginID as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: PluginDropDelegate(
                            targetID: pluginID,
                            orderedIDs: $orderedIDs,
                            draggedID: $draggedID,
                            onReorder: { persistOrder() }
                        ))
                }
            }
        }
        .onAppear { syncOrder() }
    }

    /// Build the ordered list from the canonical order, falling back to enabled-first.
    private func syncOrder() {
        let canonical = AppSettings.shared.sidebarPluginOrder
        let seed = canonical.isEmpty ? AppSettings.shared.defaultEnabledPluginIDs : canonical
        let allIDs = manifests.map(\.id)
        var result: [String] = []
        for id in seed where allIDs.contains(id) {
            result.append(id)
        }
        for id in allIDs where !result.contains(id) {
            result.append(id)
        }
        orderedIDs = result
    }

    private func moveUp(_ index: Int) {
        let disabledSet = AppSettings.shared.disabledPluginIDsSet
        // Find the nearest visible predecessor in orderedIDs
        guard index > 0,
            let prevIndex = (0..<index).reversed().first(where: { !disabledSet.contains(orderedIDs[$0]) })
        else { return }
        orderedIDs.swapAt(index, prevIndex)
        persistOrder()
    }

    private func moveDown(_ index: Int) {
        let disabledSet = AppSettings.shared.disabledPluginIDsSet
        // Find the nearest visible successor in orderedIDs
        guard index < orderedIDs.count - 1,
            let nextIndex = ((index + 1)..<orderedIDs.count).first(where: { !disabledSet.contains(orderedIDs[$0]) })
        else { return }
        orderedIDs.swapAt(index, nextIndex)
        persistOrder()
    }

    /// Save the current order back to settings.
    /// Persists both the enabled-only list and the full canonical order.
    private func persistOrder() {
        AppSettings.shared.sidebarPluginOrder = orderedIDs
        let enabledSet = Set(AppSettings.shared.defaultEnabledPluginIDs)
        let newOrder = orderedIDs.filter { enabledSet.contains($0) }
        AppSettings.shared.defaultEnabledPluginIDs = newOrder
    }
}

/// Drop delegate that reorders plugins by moving the dragged item to the drop target's position.
private struct PluginDropDelegate: DropDelegate {
    let targetID: String
    @Binding var orderedIDs: [String]
    @Binding var draggedID: String?
    let onReorder: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        onReorder()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedID, dragged != targetID,
            let fromIndex = orderedIDs.firstIndex(of: dragged),
            let toIndex = orderedIDs.firstIndex(of: targetID)
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            orderedIDs.move(
                fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }
}

private struct PluginSettingControl: View {
    let pluginID: String
    let setting: PluginManifest.SettingManifest
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    var body: some View {
        let _ = observer.revision
        switch setting.type {
        case .bool:
            boolControl
        case .double:
            doubleControl
        case .string:
            stringControl
        case .int:
            EmptyView()
        }
    }

    private var boolControl: some View {
        let value = AppSettings.shared.pluginBool(
            pluginID, setting.key, default: setting.defaultValue?.value as? Bool ?? false)
        return ToggleRow(
            label: setting.label,
            isOn: Binding(
                get: { value },
                set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
            ))
    }

    private var doubleControl: some View {
        let value = AppSettings.shared.pluginDouble(
            pluginID, setting.key, default: setting.defaultValue?.value as? Double ?? 0)
        let lo = setting.min ?? 0
        let hi = setting.max ?? 100
        let step = setting.step ?? 1
        return HStack {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(Tokens.current.text)
            Spacer()
            Slider(
                value: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                ), in: lo...hi, step: step
            )
            Text(step < 1 ? String(format: "%.1f", value) : "\(Int(value))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Tokens.current.text)
                .frame(width: 32)
        }
        .frame(width: 200)
    }

    private var stringControl: some View {
        let value = AppSettings.shared.pluginString(
            pluginID, setting.key, default: setting.defaultValue?.value as? String ?? "")
        return Group {
            if setting.options == "fontPicker:system" {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    fontPicker(value: value, fonts: AppSettings.availableSystemFonts)
                }
            } else if setting.options == "fontPicker:mono" {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    fontPicker(value: value, fonts: AppSettings.availableMonospaceFonts)
                }
            } else if setting.options == "timgStatus" {
                timgStatusControl
            } else if setting.options == "editorExtensions" {
                editorExtensionsControl(value: value)
            } else {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    TextField(
                        "",
                        text: Binding(
                            get: { value },
                            set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                }
            }
        }
    }

    private var timgStatusControl: some View {
        let installed = LocalFileTreePlugin.timgPath
        return HStack(spacing: 6) {
            Circle()
                .fill(installed != nil ? Color.green : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 7, height: 7)
            if let path = installed {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Tokens.current.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("timg not found — install via Homebrew: brew install timg")
                    .font(.system(size: 11))
                    .foregroundColor(Tokens.current.muted)
            }
        }
    }

    private func editorExtensionsControl(value: String) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            TextField(
                LocalFileTreePlugin.defaultEditorExtensions,
                text: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            Text("Comma-separated. Other file types open with the default app.")
                .font(.system(size: 11))
                .foregroundColor(t.muted)
        }
    }

    private func dockerSocketControl(value: String) -> some View {
        let docker = DockerService.shared
        let connected = docker.isAvailable
        let resolvedPath = docker.socketPath ?? "none"
        let errorMsg = docker.connectionError

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                if connected {
                    Text("Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Tokens.current.text)
                    Text(resolvedPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Tokens.current.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(errorMsg ?? "Disconnected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                }
            }
            HStack(spacing: 6) {
                Text(setting.label)
                    .font(.system(size: 11))
                    .foregroundColor(Tokens.current.muted)
                TextField(
                    "auto-detect",
                    text: Binding(
                        get: { value },
                        set: {
                            AppSettings.shared.setPluginSetting(
                                pluginID, setting.key, $0)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func fontPicker(value: String, fonts: [String]) -> some View {
        let displayValue = value.isEmpty ? "System Default" : value
        return Picker(
            "",
            selection: Binding(
                get: { displayValue },
                set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0 == "System Default" ? "" : $0) }
            )
        ) {
            ForEach(fonts, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 150)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsView: View {
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
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
                TextField("Filter shortcuts", text: $searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .foregroundColor(t.text)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(t.muted)
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
                    .foregroundColor(t.muted)
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
                .foregroundColor(t.muted)
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .font(.system(size: 12))
                        .foregroundColor(t.text)
                    Spacer()
                    Text(item.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(t.accent)
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

// MARK: - Hosting View (no safe area)

private class NoSafeAreaHostingView<Root: View>: NSHostingView<Root> {
    override var safeAreaInsets: NSEdgeInsets { .init() }
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var settingsObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        // Prevent the window from participating in key view loop
        // so sidebar items don't get focus rings
        window.autorecalculatesKeyViewLoop = false
        let theme = AppSettings.shared.theme
        window.backgroundColor = theme.chromeBg
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let hostingView = NoSafeAreaHostingView(rootView: SettingsView())
        window.contentView = hostingView

        super.init(window: window)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let t = AppSettings.shared.theme
            self?.window?.backgroundColor = t.chromeBg
            self?.window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
