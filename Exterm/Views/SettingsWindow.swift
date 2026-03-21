import Cocoa
import SwiftUI

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
        case theme = "Theme"
        case terminal = "Terminal"
        case statusBar = "Status Bar"
        case layout = "Layout"
        case plugins = "Plugins"
        case shortcuts = "Shortcuts"

        var icon: String {
            switch self {
            case .theme: return "paintpalette"
            case .terminal: return "terminal"
            case .statusBar: return "rectangle.bottomthird.inset.filled"
            case .layout: return "rectangle.3.group"
            case .plugins: return "puzzlepiece"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selectedTab: Tab = .theme
    @ObservedObject private var observer = SettingsObserver()

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        HStack(spacing: 0) {
            sidebar(t)

            Rectangle()
                .fill(t.muted.opacity(0.2))
                .frame(width: 0.5)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 480)
        .background(t.bg)
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
        case .theme: ThemeSettingsView()
        case .terminal: TerminalSettingsView()
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
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(t.text)
                content()
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

}

/// Labeled group within a page.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Tokens.current.muted)
            content()
        }
    }

}

// MARK: - Reusable Controls

private struct FontSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        let t = Tokens.current
        HStack {
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value))pt")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(t.text)
                .frame(width: 32)
        }
    }

}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(.system(size: 12))
            .foregroundColor(Tokens.current.text)
    }

}

// MARK: - Theme

private struct ThemeSettingsView: View {
    @State private var selectedTheme = AppSettings.shared.themeName
    @State private var autoTheme = AppSettings.shared.autoTheme
    @State private var darkTheme = AppSettings.shared.darkThemeName
    @State private var lightTheme = AppSettings.shared.lightThemeName
    @ObservedObject private var observer = SettingsObserver()

    private var darkThemes: [TerminalTheme] { TerminalTheme.themes.filter { $0.isDark } }
    private var lightThemes: [TerminalTheme] { TerminalTheme.themes.filter { !$0.isDark } }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Color Theme") {
            Section(title: "System Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    ToggleRow(label: "Match system dark/light mode", isOn: $autoTheme)
                        .onChange(of: autoTheme) { v in AppSettings.shared.autoTheme = v }

                    if autoTheme {
                        HStack(spacing: 12) {
                            variantPicker("Dark", selection: $darkTheme, options: darkThemes)
                                .onChange(of: darkTheme) { v in AppSettings.shared.darkThemeName = v }
                            variantPicker("Light", selection: $lightTheme, options: lightThemes)
                                .onChange(of: lightTheme) { v in AppSettings.shared.lightThemeName = v }
                        }
                    }
                }
            }

            if !autoTheme {
                Section(title: "Theme") {
                    ForEach(TerminalTheme.themes, id: \.name) { theme in
                        themeRow(theme, tokens: t)
                    }
                }
            }
        }
    }

    private func variantPicker(_ label: String, selection: Binding<String>, options: [TerminalTheme]) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(t.muted)
            Picker("", selection: selection) {
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
        }
    }

    private func themeRow(_ theme: TerminalTheme, tokens t: Tokens) -> some View {
        let active = selectedTheme == theme.name
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                colorSwatch(r: theme.background.r, g: theme.background.g, b: theme.background.b)
                ForEach(0..<6, id: \.self) { i in
                    let c = theme.ansiColors[i + 1]
                    colorSwatch(r: c.r, g: c.g, b: c.b)
                }
            }
            Text(theme.name)
                .font(.system(size: 12))
                .foregroundColor(active ? t.text : t.muted)
            Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 8))
                .foregroundColor(t.muted.opacity(0.4))
            Spacer()
            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(t.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? t.accent.opacity(0.1) : Color.clear)
        )
        .onTapGesture {
            selectedTheme = theme.name
            AppSettings.shared.themeName = theme.name
        }
    }

    private func colorSwatch(r: UInt8, g: UInt8, b: UInt8) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
            .frame(width: 14, height: 14)
    }
}

// MARK: - Terminal

private struct TerminalSettingsView: View {
    @State private var cursorStyle = AppSettings.shared.cursorStyle
    @State private var fontSize = Double(AppSettings.shared.fontSize)
    @State private var selectedFont = AppSettings.shared.fontName
    @ObservedObject private var observer = SettingsObserver()

    private let fonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Terminal") {
            Section(title: "Font") {
                Picker("", selection: $selectedFont) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: selectedFont) { v in AppSettings.shared.fontName = v }
            }

            Section(title: "Font Size") {
                FontSlider(value: $fontSize, range: 10...28)
                    .onChange(of: fontSize) { v in AppSettings.shared.fontSize = CGFloat(v) }
            }

            Section(title: "Cursor") {
                Picker("", selection: $cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: cursorStyle) { v in AppSettings.shared.cursorStyle = v }
            }

            Section(title: "Preview") {
                Text("$ echo \"Hello, Exterm\"")
                    .font(.custom(selectedFont, size: CGFloat(fontSize)))
                    .foregroundColor(t.fg)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.termBg))
            }
        }
    }

}

// MARK: - Status Bar

private struct StatusBarSettingsView: View {
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showConnection = AppSettings.shared.statusBarShowConnection
    @ObservedObject private var observer = SettingsObserver()

    var body: some View {
        let _ = observer.revision
        SettingsPage(title: "Status Bar") {
            Section(title: "Left Segments") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Connection", isOn: $showConnection)
                        .onChange(of: showConnection) { v in AppSettings.shared.statusBarShowConnection = v }
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

}

// MARK: - Layout

struct LayoutSettingsView: View {
    @State private var sidebarPosition = AppSettings.shared.sidebarPosition
    @State private var workspaceBarPosition = AppSettings.shared.workspaceBarPosition
    @State private var tabOverflowMode = AppSettings.shared.tabOverflowMode
    @ObservedObject private var observer = SettingsObserver()

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Layout") {
            Section(title: "Sidebar Position") {
                Picker("", selection: $sidebarPosition) {
                    ForEach(SidebarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sidebarPosition) { v in AppSettings.shared.sidebarPosition = v }
            }

            Section(title: "Workspace Bar Position") {
                Picker("", selection: $workspaceBarPosition) {
                    ForEach(WorkspaceBarPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: workspaceBarPosition) { v in AppSettings.shared.workspaceBarPosition = v }
            }

            Section(title: "Tab Overflow") {
                Picker("", selection: $tabOverflowMode) {
                    ForEach(TabOverflowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tabOverflowMode) { v in AppSettings.shared.tabOverflowMode = v }
            }
        }
        .foregroundColor(t.text)
    }

}

// MARK: - Plugins

struct PluginSettingsView: View {
    /// Set by MainWindowController before showing settings.
    static var registeredManifests: [PluginManifest] = []

    @ObservedObject private var observer = SettingsObserver()

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        let manifests = Self.registeredManifests

        SettingsPage(title: "Plugins") {
            Text("Built-in plugins provide core functionality. External plugins are loaded from ~/.exterm/plugins/")
                .font(.system(size: 11))
                .foregroundColor(t.muted)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(manifests, id: \.id) { manifest in
                    PluginRow(manifest: manifest)
                }
            }

            Section(title: "Default Sidebar Plugins") {
                Text("Plugins shown in the sidebar when opening a new pane or starting the app.")
                    .font(.system(size: 10))
                    .foregroundColor(t.muted)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manifests.filter { $0.capabilities?.sidebarPanel == true }, id: \.id) { manifest in
                        DefaultEnabledRow(manifest: manifest)
                    }
                }
            }
        }
    }

}

private struct PluginRow: View {
    let manifest: PluginManifest

    @State private var isEnabled: Bool
    @State private var isExpanded: Bool = false
    @ObservedObject private var observer = SettingsObserver()

    init(manifest: PluginManifest) {
        self.manifest = manifest
        self._isEnabled = State(initialValue: !AppSettings.shared.disabledPluginIDs.contains(manifest.id))
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
                        Text("Built-in")
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
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(t.muted)
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

private struct DefaultEnabledRow: View {
    let manifest: PluginManifest
    @State private var isEnabled: Bool
    @ObservedObject private var observer = SettingsObserver()

    init(manifest: PluginManifest) {
        self.manifest = manifest
        self._isEnabled = State(
            initialValue: AppSettings.shared.defaultEnabledPluginIDs.contains(manifest.id))
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        Toggle(manifest.name, isOn: $isEnabled)
            .font(.system(size: 12))
            .foregroundColor(t.text)
            .onChange(of: isEnabled) { enabled in
                var list = AppSettings.shared.defaultEnabledPluginIDs
                if enabled {
                    if !list.contains(manifest.id) { list.append(manifest.id) }
                } else {
                    list.removeAll { $0 == manifest.id }
                }
                AppSettings.shared.defaultEnabledPluginIDs = list
            }
    }
}

private struct PluginSettingControl: View {
    let pluginID: String
    let setting: PluginManifest.SettingManifest
    @ObservedObject private var observer = SettingsObserver()

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
        return HStack {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(Tokens.current.text)
            Spacer()
            FontSlider(
                value: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                ), range: 9...20
            )
            .frame(width: 150)
        }
    }

    private var stringControl: some View {
        let value = AppSettings.shared.pluginString(
            pluginID, setting.key, default: setting.defaultValue?.value as? String ?? "")
        return HStack {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(Tokens.current.text)
            Spacer()
            if setting.options == "fontPicker:system" {
                fontPicker(value: value, fonts: AppSettings.availableSystemFonts)
            } else if setting.options == "fontPicker:mono" {
                fontPicker(value: value, fonts: AppSettings.availableMonospaceFonts)
            } else {
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
    @ObservedObject private var observer = SettingsObserver()

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

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Keyboard Shortcuts") {
            ForEach(Self.groups, id: \.0) { group in
                shortcutGroup(title: group.0, items: group.1, tokens: t)
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

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var settingsObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        // Prevent the window from participating in key view loop
        // so sidebar items don't get focus rings
        window.autorecalculatesKeyViewLoop = false
        let theme = AppSettings.shared.theme
        window.backgroundColor = theme.sidebarBg
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: SettingsView())

        super.init(window: window)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let t = AppSettings.shared.theme
            self?.window?.backgroundColor = t.sidebarBg
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
