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
        .frame(width: 720, height: 520)
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
    var spacing: CGFloat = 10
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(padding)
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
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.current.text)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 0)
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
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
    }
}
