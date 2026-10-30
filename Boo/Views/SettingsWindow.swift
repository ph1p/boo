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

    /// The island backdrop and hairline, read from the same theme properties the
    /// AppKit chrome uses so the settings window matches the main window rather
    /// than approximating it.
    var backdrop: Color { Color(nsColor: theme.windowBackdrop) }
    var islandBorder: Color { Color(nsColor: theme.islandBorder) }
    var cardBg: Color { Color(nsColor: theme.cardBg) }

    /// Generic mirror: any TerminalTheme color as SwiftUI Color. Every current
    /// and future token is reachable via `t.color(\.hoverFill)` — the named
    /// mirrors below are just ergonomic shorthands for the common ones.
    func color(_ keyPath: KeyPath<TerminalTheme, NSColor>) -> Color {
        Color(nsColor: theme[keyPath: keyPath])
    }

    // Semantic tokens — SwiftUI mirrors of the TerminalTheme derived tokens.
    // Prefer these over `muted.opacity(…)` so alphas stay consistent app-wide.
    var textSecondary: Color { Color(nsColor: theme.textSecondary) }
    var textTertiary: Color { Color(nsColor: theme.textTertiary) }
    var separator: Color { Color(nsColor: theme.separator) }
    var hoverFill: Color { Color(nsColor: theme.hoverFill) }
    var subtleFill: Color { Color(nsColor: theme.subtleFill) }
    var controlFill: Color { Color(nsColor: theme.controlFill) }
    var accentSelectionFill: Color { Color(nsColor: theme.accentSelectionFill) }
    var accentEmphasis: Color { Color(nsColor: theme.accentEmphasis) }
    var focusRing: Color { Color(nsColor: theme.focusRing) }
    var success: Color { Color(nsColor: theme.success) }
    var warning: Color { Color(nsColor: theme.warning) }
    var error: Color { Color(nsColor: theme.error) }
    var info: Color { Color(nsColor: theme.info) }
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

// The settings tree reads its tokens from the environment, seeded once per
// render by the root `SettingsView` (which observes theme changes). Reading
// `Tokens.current` directly from a leaf view's `body` is a staleness bug:
// SwiftUI skips re-rendering rows whose stored inputs didn't change, so a
// theme switch leaves them painted with the previous theme's colors.
extension EnvironmentValues {
    @Entry var tokens: Tokens = Tokens(theme: .defaultDark)
}

// MARK: - Root

struct SettingsView: View {
    enum Tab: Hashable {
        case general
        case theme
        case appearance
        case statusBar
        case layout
        case profiles
        case rules
        case recordings
        case permissions
        case editor
        case browser
        case notifications
        case plugins
        case shortcuts
        case pluginSettings(pluginID: String)

        /// Sidebar sections, in display order.
        enum Group: String, CaseIterable {
            case terminal = "Terminal"
            case appearance = "Appearance"
            case apps = "Apps"
            case plugins = "Plugins"
        }

        static var fixed: [Tab] {
            [
                .general, .profiles, .rules, .shortcuts, .recordings, .permissions,
                .theme, .appearance, .statusBar, .layout,
                .editor, .browser, .notifications,
                .plugins
            ]
        }

        var group: Group {
            switch self {
            case .general, .profiles, .rules, .shortcuts, .recordings, .permissions: return .terminal
            case .theme, .appearance, .statusBar, .layout: return .appearance
            case .editor, .browser, .notifications: return .apps
            case .plugins, .pluginSettings: return .plugins
            }
        }

        /// What the page holds, so the sidebar filter finds "font" or "sync"
        /// without the user knowing which page has it.
        var keywords: String {
            switch self {
            case .general:
                return "folder startup sync history scrollback restore budget agent debug logging ignore"
            case .theme: return "colors dark light system mode custom import iterm2 ghostty palette"
            case .appearance: return "font size cursor shader sidebar font terminal font"
            case .statusBar: return "segments git clock battery status"
            case .layout: return "sidebar workspace bar tab groups pane controls tab overflow vertical tabs"
            case .profiles: return "profile shell command environment ssh directory"
            case .rules: return "regex trigger highlight notify confirm confirmation automation"
            case .recordings: return "record asciinema cast video export markers idle"
            case .permissions:
                return "privacy full disk access files folders automation developer tools signature prompts tcc"
            case .editor: return "code font tab size spaces line numbers minimap word wrap format external"
            case .browser: return "home page history website data links close"
            case .notifications: return "alerts command duration ports bursts"
            case .plugins: return "extensions installed enable disable"
            case .shortcuts: return "keyboard keys bindings rebind hotkey quick terminal"
            case .pluginSettings(let id): return id
            }
        }

        /// Tabs whose label or keywords contain every word of `query`.
        static func matching(_ query: String, in tabs: [Tab]) -> [Tab] {
            let words = query.lowercased().split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return tabs }
            return tabs.filter { tab in
                let haystack = (tab.label + " " + tab.keywords).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }

        var label: String {
            switch self {
            case .general: return "General"
            case .theme: return "Theme"
            case .appearance: return "Appearance"
            case .statusBar: return "Status Bar"
            case .layout: return "Layout"
            case .profiles: return "Profiles"
            case .rules: return "Rules"
            case .recordings: return "Recordings"
            case .permissions: return "Permissions"
            case .editor: return "Editor"
            case .browser: return "Browser"
            case .notifications: return "Notifications"
            case .plugins: return "Plugins"
            case .shortcuts: return "Shortcuts"
            case .pluginSettings(let id):
                return PluginSettingsView.registeredManifests.first(where: { $0.id == id })?.name ?? id
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .theme: return "paintpalette"
            case .appearance: return "textformat.size"
            case .statusBar: return "rectangle.bottomthird.inset.filled"
            case .layout: return "square.grid.2x2"
            case .profiles: return "person.crop.rectangle.stack"
            case .rules: return "wand.and.stars"
            case .recordings: return "record.circle"
            case .permissions: return "lock.shield"
            case .editor: return "curlybraces"
            case .browser: return "globe"
            case .notifications: return "bell"
            case .plugins: return "puzzlepiece"
            case .shortcuts: return "command"
            case .pluginSettings(let id):
                return PluginSettingsView.registeredManifests.first(where: { $0.id == id })?.icon ?? "puzzlepiece"
            }
        }
    }

    @State private var selectedTab: Tab? = .general
    @State private var query = ""
    /// A tab asked for from outside (e.g. "Edit Profiles…"); taken by the view.
    nonisolated(unsafe) static var requestedTab: Tab?
    static let selectTabNotification = Notification.Name("BooSettingsSelectTab")
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

    /// Icons centred in one fixed-width column, so wide and narrow symbols
    /// alike leave every title starting at the same x.
    private func sidebarLabel(_ tab: Tab) -> some View {
        Label {
            Text(tab.label)
        } icon: {
            Image(systemName: tab.icon)
                .frame(width: 22, alignment: .center)
                .padding(.trailing, 4)
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        VStack(spacing: 0) {
            header(t)

            HStack(spacing: IslandMetrics.gap) {
                // Sidebar island
                VStack(spacing: 0) {
                    SettingTextField(
                        placeholder: "Search", text: $query, icon: "magnifyingglass", trailingClear: true,
                        onCommit: selectFirstMatch
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    let visible = Tab.matching(query, in: Tab.fixed + pluginTabs)
                    List(selection: $selectedTab) {
                        ForEach(Tab.Group.allCases, id: \.self) { group in
                            let tabs = visible.filter { $0.group == group }
                            if !tabs.isEmpty {
                                SwiftUI.Section(group.rawValue) {
                                    ForEach(tabs, id: \.label) { tab in
                                        sidebarLabel(tab).tag(tab)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if visible.isEmpty {
                            Text("No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(t.textTertiary)
                        }
                    }
                }
                .frame(width: 190)
                .island(t)

                // Detail island
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .island(t)
            }
        }
        // The gap around the islands is the window backdrop showing through, the
        // same as in the main window — the islands float on it rather than tiling it.
        // No top padding: the header above them carries its own vertical inset.
        .padding(.horizontal, IslandMetrics.gap)
        .padding(.bottom, IslandMetrics.gap)
        .background(t.backdrop)
        .frame(width: 780, height: 560)
        // One tokens snapshot per render for the whole tree — and the environment
        // change is what forces otherwise-unchanged rows to repaint on theme switch.
        .environment(\.tokens, t)
        .onAppear(perform: takeRequestedTab)
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTabNotification)) { _ in takeRequestedTab() }
    }

    /// Return in the search field opens the first match.
    private func selectFirstMatch() {
        if let first = Tab.matching(query, in: Tab.fixed + pluginTabs).first { selectedTab = first }
    }

    private func takeRequestedTab() {
        guard let tab = Self.requestedTab else { return }
        Self.requestedTab = nil
        selectedTab = tab
    }

    /// The window's header strip: traffic lights on the left, title centred on the
    /// window. Mirrors the main window's toolbar — same height, same vertical inset,
    /// same centred-title treatment — so the two windows read as one app. It paints
    /// no fill and carries no border, exactly like the toolbar it echoes.
    @ViewBuilder
    private func header(_ t: Tokens) -> some View {
        // Centred on the cap band, not the line box — the same correction the
        // toolbar's `centeredWorkspaceTitleRect` applies, via the shared helper,
        // so the two windows' titles sit on the same midline.
        let capOffset = IslandMetrics.capCenterOffset(font: ToolbarView.Fonts.headerTitle)
        Text("Settings")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(t.text)
            .frame(maxWidth: .infinity)
            .offset(y: capOffset)
            .frame(height: IslandMetrics.toolbarHeight)
            .padding(.top, IslandMetrics.barGap)
            .padding(.bottom, IslandMetrics.headerBottomGap)
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
        case .profiles: ProfilesSettingsView()
        case .rules: RulesSettingsView()
        case .recordings: RecordingsSettingsView()
        case .permissions: PermissionsSettingsView()
        case .editor: EditorSettingsView()
        case .browser: BrowserSettingsView()
        case .notifications: NotificationsSettingsView()
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

extension View {
    /// Render this view as an island: the chrome fill, clipped to the shared corner
    /// radius, with the same hairline every island in the main window carries.
    func island(_ t: Tokens) -> some View {
        self
            .background(t.bg)
            .clipShape(RoundedRectangle(cornerRadius: IslandMetrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: IslandMetrics.radius, style: .continuous)
                    .strokeBorder(t.islandBorder, lineWidth: IslandMetrics.borderWidth))
    }
}

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

/// A titled card. Its direct children are rows, separated by hairlines.
/// `footer` is muted text under the card for notes about the whole section.
struct Section<Content: View>: View {
    let title: String
    var footer: String? = nil
    var dividers: Bool = true
    @ViewBuilder let content: () -> Content
    @Environment(\.tokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.muted)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: dividers ? 0 : Tokens.rowSpacing) {
                Group(subviews: content()) { rows in
                    ForEach(rows) { row in
                        if dividers && row.id != rows.first?.id { SettingsRowDivider() }
                        row.padding(.vertical, dividers ? Tokens.rowSpacing - 2 : 0)
                    }
                }
            }
            .padding(.horizontal, Tokens.sectionPadding)
            .padding(.vertical, dividers ? 2 : Tokens.sectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tokens.separator, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Hairline between rows of a list or card.
struct SettingsRowDivider: View {
    @Environment(\.tokens) private var tokens

    var body: some View {
        Rectangle().fill(tokens.separator).frame(height: 0.5)
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

/// Label on the left, switch on the right.
struct ToggleRow: View {
    let label: String
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label, help: help, alignment: .center) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Unified Settings Row

/// Label on the left, control trailing, optional help underneath. Primary
/// building block for settings pages; a control that wants the full width
/// (a text field) fills the space after the label.
struct SettingRow<Control: View>: View {
    @Environment(\.tokens) private var tokens
    let label: String
    var help: String? = nil
    var alignment: VerticalAlignment = .center
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: alignment, spacing: 12) {
                SettingLabel(text: label)
                    .frame(minWidth: Tokens.labelWidth, alignment: .leading)
                    .layoutPriority(1)
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

/// The 12pt row label shared by every row type.
struct SettingLabel: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tokens.text)
    }
}

/// Standalone 11pt muted description line.
struct DescriptionLabel: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tokens.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row for wide controls (segmented pickers): label and control side by
/// side like `SettingRow` when the control fits, label above it when not.
struct SettingStack<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SettingLabel(text: label)
                        .frame(minWidth: Tokens.labelWidth, alignment: .leading)
                        .fixedSize()
                    Spacer(minLength: 0)
                    control().fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel(text: label)
                    control()
                }
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

/// A folder (or file) setting: label with the current path under it, actions
/// trailing. An empty `path` shows `placeholder` instead.
struct PathRow<Actions: View>: View {
    @Environment(\.tokens) private var tokens
    let label: String
    let path: String
    var placeholder: String = "None"
    var help: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingLabel(text: label)
                    Text(path.isEmpty ? placeholder : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: path.isEmpty ? .default : .monospaced))
                        .foregroundStyle(tokens.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) { actions() }
                    .buttonStyle(.themed)
                    .fixedSize()
            }
            if let help { DescriptionLabel(text: help) }
        }
    }
}

// MARK: - Text Field

/// Themed text field matching the settings visual language.
struct SettingTextField: View {
    @Environment(\.tokens) private var tokens
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var width: CGFloat? = nil
    var icon: String? = nil
    var trailingClear: Bool = false
    var onCommit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        let t = tokens
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
                .focused($focused)
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
        .themedFieldChrome(focused: focused)
        .frame(width: width)
    }
}

struct SettingNumberField: View {
    @Environment(\.tokens) private var tokens
    @Binding var value: Int
    var width: CGFloat = 70
    var alignment: TextAlignment = .trailing
    var onCommit: ((Int) -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .multilineTextAlignment(alignment)
            .foregroundStyle(tokens.text)
            .focused($focused)
            .themedFieldChrome(focused: focused)
            .frame(width: width)
            .onChange(of: value) { _, v in onCommit?(v) }
    }
}

// MARK: - Icon Button

/// Small icon button used for inline row actions (delete, edit).
struct IconButton: View {
    @Environment(\.tokens) private var tokens
    let systemName: String
    var tint: Color? = nil
    var size: CGFloat = 11
    var frame: CGFloat = 22
    var fillOpacity: Double = 0.12
    var help: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let t = tokens
        let color = tint ?? t.muted
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .frame(width: frame, height: frame)
                .foregroundStyle(hovered ? t.text : color)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(hovered ? fillOpacity * 2 : fillOpacity))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

// MARK: - Shortcut Pill

struct ShortcutPill: View {
    @Environment(\.tokens) private var tokens
    let text: String

    var body: some View {
        let t = tokens
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
    @Environment(\.tokens) private var tokens
    let icon: String
    let name: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let t = tokens
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
        // Behind the islands, so it is the backdrop rather than the chrome fill —
        // otherwise the margin flashes the wrong colour during a resize.
        window.backgroundColor = theme.windowBackdrop
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let hostingView = NoSafeAreaHostingView(rootView: SettingsView())
        window.contentView = hostingView
        super.init(window: window)

        // Attached like the main window: this window's 32pt `NSTitlebarView`
        // centres the buttons natively at 16pt from the top (measured), while the
        // header midline sits at `barGap + toolbarHeight / 2` = 23pt — exactly the
        // shared `offsetY` (-3 - barGap) lower, so the one positioner serves both
        // windows.
        TrafficLightPositioner.attach(to: window)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let t = AppSettings.shared.theme
                self?.window?.backgroundColor = t.windowBackdrop
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

    /// Opens the window on `tab`.
    func showSettings(tab: SettingsView.Tab) {
        SettingsView.requestedTab = tab
        NotificationCenter.default.post(name: SettingsView.selectTabNotification, object: nil)
        showSettings()
    }
}
