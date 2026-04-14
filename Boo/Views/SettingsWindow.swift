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
    enum Tab: Equatable {
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

    @State private var selectedTab: Tab = .general
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        VStack(spacing: 0) {
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
        let pluginTabs: [Tab] = PluginSettingsView.registeredManifests
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

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) {
                ForEach(Tab.fixed, id: \.label) { tab in
                    sidebarRow(tab, t: t)
                }

                if !pluginTabs.isEmpty {
                    HStack {
                        Text("PLUGINS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(t.muted)
                            .tracking(0.4)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    ForEach(pluginTabs, id: \.label) { tab in
                        sidebarRow(tab, t: t)
                    }
                }

                Spacer(minLength: 10)
            }
            .padding(10)
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(t.chromeBg)
    }

    private func sidebarRow(_ tab: Tab, t: Tokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .font(.system(size: 12))
                .frame(width: 18)
            Text(tab.label)
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
        }
    }
}

// MARK: - Settings Page Shell

/// Every tab uses this wrapper so layout is identical: title, scroll, consistent padding.
struct SettingsPage<Content: View>: View {
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
struct Section<Content: View>: View {
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

    final class Coordinator: NSObject {
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

struct ToggleRow: View {
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
