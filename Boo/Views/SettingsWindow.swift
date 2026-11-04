import Cocoa
import SwiftUI

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
            case .editor:
                return "code font tab size spaces line numbers minimap word wrap format external autosave "
                    + "whitespace cursor ligatures sticky scroll status encoding reload"
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
        // Resizable, never below the default size the pages are laid out for.
        .frame(
            minWidth: SettingsWindowController.defaultSize.width, maxWidth: .infinity,
            minHeight: SettingsWindowController.defaultSize.height, maxHeight: .infinity)
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

// MARK: - Hosting View (no safe area)

private class NoSafeAreaHostingView<Root: View>: NSHostingView<Root> {
    override var safeAreaInsets: NSEdgeInsets { .init() }
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    /// Opening size, and the smallest the window may be resized to.
    static let defaultSize = NSSize(width: 780, height: 560)

    private var settingsObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = Self.defaultSize
        window.center()
        // Remembers a resized frame across launches (applied over the centred default).
        window.setFrameAutosaveName("BooSettingsWindow")
        window.autorecalculatesKeyViewLoop = false
        let theme = AppSettings.shared.theme
        // Behind the islands, so it is the backdrop rather than the chrome fill —
        // otherwise the margin flashes the wrong colour during a resize.
        window.backgroundColor = theme.windowBackdrop
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let hostingView = NoSafeAreaHostingView(rootView: SettingsView())
        window.contentView = hostingView
        super.init(window: window)

        // Attached like the main window: the header island has the same geometry
        // (`gap` leading, `barGap` top, `toolbarHeight` tall), and the positioner
        // derives its shift from that geometry, so the one positioner serves both.
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
