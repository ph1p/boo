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
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

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
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    private var darkThemes: [TerminalTheme] { TerminalTheme.themes.filter { $0.isDark } }
    private var lightThemes: [TerminalTheme] { TerminalTheme.themes.filter { !$0.isDark } }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Color Theme") {
            // System appearance toggle
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
                Section(title: "Dark") {
                    themeGrid(darkThemes, tokens: t)
                }
                Section(title: "Light") {
                    themeGrid(lightThemes, tokens: t)
                }
            }
        }
    }

    private func variantPicker(
        _ label: String, icon: String, selection: Binding<String>, options: [TerminalTheme]
    ) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(t.muted)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(t.muted)
            }
            Picker("", selection: selection) {
                ForEach(options, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
        }
    }

    private func themeGrid(_ themes: [TerminalTheme], tokens t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(themes, id: \.name) { theme in
                themeRow(theme, tokens: t)
            }
        }
    }

    private func themeRow(_ theme: TerminalTheme, tokens t: Tokens) -> some View {
        let active = selectedTheme == theme.name
        return HStack(spacing: 0) {
            // Color bar: terminal bg + 6 ansi colors as a continuous strip
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color(theme.background))
                    .frame(width: 20)
                ForEach(0..<6, id: \.self) { i in
                    let c = theme.ansiColors[i + 1]
                    Rectangle().fill(color(c))
                }
            }
            .frame(width: 80, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? t.accent.opacity(0.5) : t.muted.opacity(0.1), lineWidth: 1)
            )

            Text(theme.name)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundColor(active ? t.text : t.muted)
                .padding(.leading, 10)

            Spacer()

            if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(t.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? t.accent.opacity(0.08) : Color.clear)
        )
        .onTapGesture {
            selectedTheme = theme.name
            AppSettings.shared.themeName = theme.name
        }
    }

    private func color(_ c: TerminalColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

// MARK: - Terminal

private struct TerminalSettingsView: View {
    @State private var cursorStyle = AppSettings.shared.cursorStyle
    @State private var fontSize = Double(AppSettings.shared.fontSize)
    @State private var selectedFont = AppSettings.shared.fontName
    @State private var debugLogging = AppSettings.shared.debugLogging
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .terminal])

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

            Section(title: "Debug") {
                VStack(alignment: .leading, spacing: 8) {
                    ToggleRow(label: "Debug logging", isOn: $debugLogging)
                        .onChange(of: debugLogging) { v in AppSettings.shared.debugLogging = v }
                }
            }
        }
    }

}

// MARK: - Status Bar

private struct StatusBarSettingsView: View {
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showConnection = AppSettings.shared.statusBarShowConnection
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .statusBar])

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

    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

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
                    .onDrop(of: [.text], delegate: PluginDropDelegate(
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
        guard index > 0 else { return }
        orderedIDs.swapAt(index, index - 1)
        persistOrder()
    }

    private func moveDown(_ index: Int) {
        guard index < orderedIDs.count - 1 else { return }
        orderedIDs.swapAt(index, index + 1)
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
            orderedIDs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
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
            } else if setting.options == "dockerSocket" {
                dockerSocketControl(value: value)
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
