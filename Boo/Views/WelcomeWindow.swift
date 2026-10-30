import Cocoa
import SwiftUI

/// The window shown on a fresh install: a theme to start with and the few
/// shortcuts that are hard to discover. Help ▸ Welcome to Boo reopens it.
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private var settingsObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Boo"
        window.isReleasedWhenClosed = false
        let theme = AppSettings.shared.theme
        window.backgroundColor = theme.sidebarBg
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: WelcomeView { [weak window] in window?.close() })
        window.center()
        super.init(window: window)

        // Picking a theme here restyles the window with it.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let t = AppSettings.shared.theme
                self?.window?.backgroundColor = t.sidebarBg
                self?.window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWelcome() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the window once, on a fresh install. Someone upgrading from a
    /// version without it has used Boo already and is not shown it.
    static func showIfFirstLaunch(returningUser: Bool) {
        guard !AppSettings.shared.welcomeShown else { return }
        AppSettings.shared.welcomeShown = true
        guard !returningUser else { return }
        shared.showWelcome()
    }
}

// MARK: - View

struct WelcomeView: View {
    let onClose: () -> Void
    @State private var selectedTheme = AppSettings.shared.themeName
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .shortcuts])

    /// A few dark and light themes; the full list is in Settings ▸ Theme.
    static let starterThemes = [
        "Default Dark", "Tokyo Night", "Catppuccin Mocha", "Dracula", "Default Light", "Catppuccin Latte",
        "Solarized Light", "GitHub Light"
    ]

    /// Menu items worth knowing on day one, by `MenuAction.id`. Shortcuts
    /// are read from the menu so rebound keys show as rebound.
    static let tips: [(id: String, text: String)] = [
        ("View/Command Palette…", "Run any command by name"),
        ("File/Open Folder...", "Open a project folder as a workspace"),
        ("Terminal/Split Right", "Split the pane; drag tabs between panes"),
        ("Terminal/Quick Select", "Label URLs, paths and hashes on screen, then copy one with a key"),
        ("Terminal/Copy Mode", "Move through the scrollback and select with vi keys"),
        ("Boo/Settings...", "Fonts, profiles, rules and shortcuts")
    ]

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Boo")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(t.text)
                    Text("Pick a theme and learn a few shortcuts. You can change everything later in Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(t.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                heading("Theme", t)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 3) {
                    ForEach(Self.starterThemes, id: \.self) { name in
                        if let theme = AppSettings.shared.theme(named: name) {
                            ThemeRow(theme: theme, selectedTheme: $selectedTheme)
                        }
                    }
                }
                Button("More themes, or import one from iTerm2 or Ghostty…") {
                    SettingsWindowController.shared.showSettings(tab: .theme)
                }
                .buttonStyle(.themedLink)
            }

            VStack(alignment: .leading, spacing: 6) {
                heading("Shortcuts", t)
                ForEach(Self.tips, id: \.id) { tip in
                    HStack(spacing: 10) {
                        Text(ActionRegistry.action(id: tip.id)?.shortcut ?? "—")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(t.text)
                            .frame(width: 64, alignment: .trailing)
                        Text(tip.text)
                            .font(.system(size: 12))
                            .foregroundStyle(t.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Documentation") {
                    if let url = URL(string: "https://ph1p.github.io/boo/") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.themed)
                Spacer()
                Button("Get Started", action: onClose)
                    .buttonStyle(.themedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 600, alignment: .topLeading)
        .background(t.bg)
        .environment(\.tokens, t)
    }

    private func heading(_ title: String, _ t: Tokens) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(t.muted)
            .textCase(.uppercase)
    }
}
