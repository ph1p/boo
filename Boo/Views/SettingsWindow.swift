import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design Tokens

/// Single source of truth for settings UI styling.
/// Every sub-view pulls from here instead of re-deriving colors inline.
struct Tokens {
    let theme: TerminalTheme
    var text: Color { Color(nsColor: theme.chromeText) }
    var muted: Color { Color(nsColor: theme.chromeMuted) }
    var accent: Color { Color(nsColor: theme.accentColor) }
    var bg: Color { Color(nsColor: theme.sidebarBg) }
    var chromeBg: Color { Color(nsColor: theme.chromeBg) }
    var border: Color { Color(nsColor: theme.sidebarBorder) }
    var cardBg: Color {
        let alpha: CGFloat = 0.12
        let fg = theme.chromeMuted
        let bg = theme.sidebarBg
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
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

    static let labelWidth: CGFloat = 112
    static let rowSpacing: CGFloat = 10
    static let sectionPadding: CGFloat = 12
}

// MARK: - Root

struct SettingsView: View {
    enum Tab: Hashable {
        case general
        case theme
        case appearance
        case statusBar
        case layout
        case editor
        case browser
        case plugins
        case shortcuts
        case pluginSettings(pluginID: String)

        static var fixed: [Tab] {
            [.general, .theme, .appearance, .statusBar, .layout, .editor, .browser, .plugins, .shortcuts]
        }

        var label: String {
            switch self {
            case .general: return "General"
            case .theme: return "Theme"
            case .appearance: return "Appearance"
            case .statusBar: return "Status Bar"
            case .layout: return "Layout"
            case .editor: return "Editor"
            case .browser: return "Browser"
            case .plugins: return "Plugins"
            case .shortcuts: return "Shortcuts"
            case .pluginSettings(let id):
                return PluginSettingsView.registeredManifests.first(where: { $0.id == id })?.name ?? id
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .theme: return "paintpalette"
            case .appearance: return "textformat"
            case .statusBar: return "rectangle.bottomthird.inset.filled"
            case .layout: return "rectangle.3.group"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            case .browser: return "globe"
            case .plugins: return "puzzlepiece"
            case .shortcuts: return "keyboard"
            case .pluginSettings(let id):
                return PluginSettingsView.registeredManifests.first(where: { $0.id == id })?.icon ?? "puzzlepiece"
            }
        }
    }

    @State private var selectedTab: Tab? = .general
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    private var pluginTabs: [Tab] {
        PluginSettingsView.registeredManifests
            .filter { manifest in
                let isEnabled = !AppSettings.shared.disabledPluginIDs.contains(manifest.id)
                let hasSettings: Bool = {
                    guard let settings = manifest.settings, !settings.isEmpty else { return false }
                    if manifest.capabilities?.statusBarSegment == true {
                        return settings.contains { $0.type != .bool }
                    }
                    return true
                }()
                return isEnabled && hasSettings
            }
            .map { .pluginSettings(pluginID: $0.id) }
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                List(selection: $selectedTab) {
                    SwiftUI.Section("Settings") {
                        ForEach(Tab.fixed, id: \.label) { tab in
                            Label(tab.label, systemImage: tab.icon).tag(tab)
                        }
                    }
                    if !pluginTabs.isEmpty {
                        SwiftUI.Section("Plugins") {
                            ForEach(pluginTabs, id: \.label) { tab in
                                Label(tab.label, systemImage: tab.icon).tag(tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top) { Color.clear.frame(height: 20) }
            }
            .frame(width: 190)

            Divider()

            // Detail
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(t.bg)
        .frame(width: 780, height: 560)
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
        case .editor: EditorSettingsView()
        case .browser: BrowserSettingsView()
        case .plugins: PluginSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .pluginSettings(let id):
            if let manifest = PluginSettingsView.registeredManifests.first(where: { $0.id == id }) {
                PluginDetailSettingsView(manifest: manifest)
            }
        case nil:
            GeneralSettingsView()
        }
    }
}

// MARK: - Settings Page Shell

struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.current.muted)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: Tokens.rowSpacing) {
                content()
            }
            .padding(Tokens.sectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.current.cardBg, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
    }
}

// MARK: - Reusable Controls

struct FontSizePicker: NSViewRepresentable {
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

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            value.wrappedValue = Double(sender.selectedTag())
        }
    }
}

struct FontChooser: NSViewRepresentable {
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

    @MainActor final class Coordinator: NSObject {
        var selectedFont: Binding<String>
        init(selectedFont: Binding<String>) { self.selectedFont = selectedFont }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let title = sender.titleOfSelectedItem {
                selectedFont.wrappedValue = title
            }
        }
    }
}

struct ToggleRow: View {
    let label: String
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(t.text)
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Unified Settings Row

/// Label + control + optional help text. Primary building block for settings pages.
struct SettingRow<Control: View>: View {
    let label: String
    var help: String? = nil
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder let control: () -> Control

    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: alignment, spacing: 10) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(t.text)
                    .frame(width: Tokens.labelWidth, alignment: .leading)
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Tokens.labelWidth + 10)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Standalone 11pt muted description line — use when a row is unlabeled (e.g. segmented pickers).
struct DescriptionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Tokens.current.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Label-above-control layout for full-width controls (segmented pickers, pickers with long options).
struct SettingStack<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(t.text)
            control()
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Text Field

/// Themed text field matching the settings visual language.
struct SettingTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var width: CGFloat? = nil
    var icon: String? = nil
    var trailingClear: Bool = false
    var onCommit: (() -> Void)? = nil

    var body: some View {
        let t = Tokens.current
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(t.text)
                .onSubmit { onCommit?() }
            if trailingClear && !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(t.chromeBg.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.border, lineWidth: 1))
        )
    }
}

struct SettingNumberField: View {
    @Binding var value: Int
    var width: CGFloat = 70
    var alignment: TextAlignment = .trailing
    var onCommit: ((Int) -> Void)? = nil

    var body: some View {
        let t = Tokens.current
        TextField("", value: $value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(alignment)
            .foregroundStyle(t.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(t.chromeBg.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.border, lineWidth: 1))
            )
            .onChange(of: value) { _, v in onCommit?(v) }
    }
}

// MARK: - Icon Button

/// Small icon button used for inline row actions (delete, edit).
struct IconButton: View {
    let systemName: String
    var tint: Color? = nil
    var size: CGFloat = 11
    var frame: CGFloat = 22
    var fillOpacity: Double = 0.12
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        let t = Tokens.current
        let color = tint ?? t.muted
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .frame(width: frame, height: frame)
                .foregroundStyle(color)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(fillOpacity))
                )
        }
        .buttonStyle(.plain)
        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

// MARK: - Shortcut Pill

struct ShortcutPill: View {
    let text: String

    var body: some View {
        let t = Tokens.current
        Text(text)
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

// MARK: - Plugin Segment Group

/// Plugin header + indented toggle list used in Status Bar plugin segments and similar nested groups.
struct PluginSegmentGroup<Content: View>: View {
    let icon: String
    let name: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(t.accent)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.text)
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.leading, 20)
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
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.autorecalculatesKeyViewLoop = false
        let theme = AppSettings.shared.theme
        window.backgroundColor = theme.chromeBg
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let hostingView = NoSafeAreaHostingView(rootView: SettingsView())
        window.contentView = hostingView
        TrafficLightPositioner.attach(to: window)

        super.init(window: window)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let t = AppSettings.shared.theme
                self?.window?.backgroundColor = t.chromeBg
                self?.window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let w = window {
            DispatchQueue.main.async {
                TrafficLightPositioner.apply(to: w)
            }
        }
    }
}
