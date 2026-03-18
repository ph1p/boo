import Cocoa
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case theme = "Theme"
        case terminal = "Terminal"
        case explorer = "Explorer"
        case statusBar = "Status Bar"
        case shortcuts = "Shortcuts"

        var icon: String {
            switch self {
            case .theme: return "paintpalette"
            case .terminal: return "terminal"
            case .explorer: return "sidebar.left"
            case .statusBar: return "rectangle.bottomthird.inset.filled"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selectedTab: Tab = .theme
    @ObservedObject var settings = SettingsObserver()

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme

        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
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
                        .foregroundColor(selectedTab == tab
                            ? Color(nsColor: theme.chromeText)
                            : Color(nsColor: theme.chromeMuted))
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab
                                    ? Color(nsColor: theme.accentColor).opacity(0.15)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 140)
            .background(Color(nsColor: theme.chromeBg))

            // Divider
            Rectangle()
                .fill(Color(nsColor: theme.chromeMuted).opacity(0.2))
                .frame(width: 0.5)

            // Content
            VStack {
                switch selectedTab {
                case .theme:
                    ThemeSettingsView()
                case .terminal:
                    TerminalSettingsView()
                case .explorer:
                    ExplorerSettingsView()
                case .statusBar:
                    StatusBarSettingsView()
                case .shortcuts:
                    ShortcutsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 440)
        .background(Color(nsColor: theme.sidebarBg))
    }
}

// MARK: - Theme

struct ThemeSettingsView: View {
    @State private var selectedTheme: String = AppSettings.shared.themeName

    var body: some View {
        let theme = AppSettings.shared.theme

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Color Theme")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .padding(.bottom, 4)

                ForEach(TerminalTheme.themes, id: \.name) { t in
                    HStack(spacing: 10) {
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: Double(t.background.r)/255, green: Double(t.background.g)/255, blue: Double(t.background.b)/255))
                                .frame(width: 14, height: 14)
                            ForEach(0..<6, id: \.self) { i in
                                let c = t.ansiColors[i + 1]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255))
                                    .frame(width: 14, height: 14)
                            }
                        }

                        Text(t.name)
                            .font(.system(size: 12))
                            .foregroundColor(selectedTheme == t.name
                                ? Color(nsColor: theme.chromeText)
                                : Color(nsColor: theme.chromeMuted))

                        Spacer()

                        if selectedTheme == t.name {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(nsColor: theme.accentColor))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTheme == t.name
                                ? Color(nsColor: theme.accentColor).opacity(0.1)
                                : Color.clear)
                    )
                    .onTapGesture {
                        selectedTheme = t.name
                        AppSettings.shared.themeName = t.name
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Terminal

struct TerminalSettingsView: View {
    @State private var cursorStyle: CursorStyle = AppSettings.shared.cursorStyle
    @State private var fontSize: Double = Double(AppSettings.shared.fontSize)
    @State private var selectedFont: String = AppSettings.shared.fontName

    private let fonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let theme = AppSettings.shared.theme
        let label = Color(nsColor: theme.chromeMuted)
        let text = Color(nsColor: theme.chromeText)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(text)

                SettingsSection(title: "Font", label: label) {
                    Picker("", selection: $selectedFont) {
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: selectedFont) { v in AppSettings.shared.fontName = v }
                }

                SettingsSection(title: "Font Size", label: label) {
                    HStack {
                        Slider(value: $fontSize, in: 10...28, step: 1)
                            .onChange(of: fontSize) { v in AppSettings.shared.fontSize = CGFloat(v) }
                        Text("\(Int(fontSize))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(text)
                            .frame(width: 32)
                    }
                }

                SettingsSection(title: "Cursor", label: label) {
                    Picker("", selection: $cursorStyle) {
                        ForEach(CursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: cursorStyle) { v in AppSettings.shared.cursorStyle = v }
                }

                // Preview
                SettingsSection(title: "Preview", label: label) {
                    Text("$ echo \"Hello, Exterm\"")
                        .font(.custom(selectedFont, size: CGFloat(fontSize)))
                        .foregroundColor(Color(red: Double(theme.foreground.r)/255, green: Double(theme.foreground.g)/255, blue: Double(theme.foreground.b)/255))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: Double(theme.background.r)/255, green: Double(theme.background.g)/255, blue: Double(theme.background.b)/255))
                        )
                }

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Explorer

struct ExplorerSettingsView: View {
    @State private var showHeader = AppSettings.shared.showExplorerHeader
    @State private var showHidden = AppSettings.shared.showHiddenFiles
    @State private var showIcons = AppSettings.shared.explorerIconsEnabled
    @State private var explorerFontSize: Double = Double(AppSettings.shared.explorerFontSize)
    @State private var explorerFont: String = AppSettings.shared.explorerFontName.isEmpty ? "System Default" : AppSettings.shared.explorerFontName

    private let fonts = AppSettings.availableSystemFonts

    var body: some View {
        let theme = AppSettings.shared.theme
        let label = Color(nsColor: theme.chromeMuted)
        let text = Color(nsColor: theme.chromeText)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("File Explorer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(text)

                SettingsSection(title: "Font", label: label) {
                    Picker("", selection: $explorerFont) {
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: explorerFont) { v in AppSettings.shared.explorerFontName = v == "System Default" ? "" : v }
                }

                SettingsSection(title: "Font Size", label: label) {
                    HStack {
                        Slider(value: $explorerFontSize, in: 9...20, step: 1)
                            .onChange(of: explorerFontSize) { v in AppSettings.shared.explorerFontSize = CGFloat(v) }
                        Text("\(Int(explorerFontSize))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(text)
                            .frame(width: 32)
                    }
                }

                SettingsSection(title: "Display", label: label) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show header", isOn: $showHeader)
                            .onChange(of: showHeader) { v in AppSettings.shared.showExplorerHeader = v }
                        Toggle("Show file icons", isOn: $showIcons)
                            .onChange(of: showIcons) { v in AppSettings.shared.explorerIconsEnabled = v }
                        Toggle("Show hidden files", isOn: $showHidden)
                            .onChange(of: showHidden) { v in AppSettings.shared.showHiddenFiles = v }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(text)
                }

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Status Bar

struct StatusBarSettingsView: View {
    @State private var showPath = AppSettings.shared.statusBarShowPath
    @State private var showGit = AppSettings.shared.statusBarShowGitBranch
    @State private var showTime = AppSettings.shared.statusBarShowTime
    @State private var showPaneInfo = AppSettings.shared.statusBarShowPaneInfo
    @State private var showShell = AppSettings.shared.statusBarShowShell

    var body: some View {
        let theme = AppSettings.shared.theme
        let label = Color(nsColor: theme.chromeMuted)
        let text = Color(nsColor: theme.chromeText)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Status Bar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(text)

                SettingsSection(title: "Left Side", label: label) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Git branch", isOn: $showGit)
                            .onChange(of: showGit) { v in AppSettings.shared.statusBarShowGitBranch = v }
                        Toggle("Current path", isOn: $showPath)
                            .onChange(of: showPath) { v in AppSettings.shared.statusBarShowPath = v }
                        Toggle("Running process", isOn: $showShell)
                            .onChange(of: showShell) { v in AppSettings.shared.statusBarShowShell = v }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(text)
                }

                SettingsSection(title: "Right Side", label: label) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Pane & tab count", isOn: $showPaneInfo)
                            .onChange(of: showPaneInfo) { v in AppSettings.shared.statusBarShowPaneInfo = v }
                        Toggle("Clock", isOn: $showTime)
                            .onChange(of: showTime) { v in AppSettings.shared.statusBarShowTime = v }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(text)
                }

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Shortcuts Reference

struct ShortcutsView: View {
    var body: some View {
        let theme = AppSettings.shared.theme
        let text = Color(nsColor: theme.chromeText)
        let muted = Color(nsColor: theme.chromeMuted)
        let accent = Color(nsColor: theme.accentColor)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(text)

                ShortcutGroup(title: "General", items: [
                    ("Settings", "\u{2318},"),
                    ("New Workspace", "\u{2318}N"),
                    ("Open Folder", "\u{21E7}\u{2318}O"),
                    ("New Tab", "\u{2318}T"),
                    ("Close", "\u{2318}W"),
                    ("Reopen Tab", "\u{2318}Z"),
                    ("Close Pane", "\u{21E7}\u{2318}W"),
                    ("Switch Workspace 1-9", "\u{2318}1-9"),
                ], text: text, muted: muted, accent: accent)

                ShortcutGroup(title: "Terminal", items: [
                    ("Clear Screen", "\u{2318}K"),
                    ("Clear Scrollback", "\u{21E7}\u{2318}K"),
                    ("Split Right", "\u{2318}D"),
                    ("Split Down", "\u{21E7}\u{2318}D"),
                    ("Focus Next Pane", "\u{2318}]"),
                    ("Focus Previous Pane", "\u{2318}["),
                ], text: text, muted: muted, accent: accent)

                ShortcutGroup(title: "View", items: [
                    ("Toggle Sidebar", "\u{2318}B"),
                    ("Increase Font", "\u{2318}+"),
                    ("Decrease Font", "\u{2318}-"),
                    ("Reset Font", "\u{2318}0"),
                ], text: text, muted: muted, accent: accent)

                ShortcutGroup(title: "Edit", items: [
                    ("Copy", "\u{2318}C"),
                    ("Paste", "\u{2318}V"),
                    ("Select All", "\u{2318}A"),
                ], text: text, muted: muted, accent: accent)

                ShortcutGroup(title: "Bookmarks", items: [
                    ("Bookmark Directory", "\u{21E7}\u{2318}B"),
                    ("Jump to Bookmark 1-9", "\u{2303}1-9"),
                    ("Switch Workspace 1-9", "\u{2318}1-9"),
                ], text: text, muted: muted, accent: accent)

                Spacer()
            }
            .padding(16)
        }
    }
}

struct ShortcutGroup: View {
    let title: String
    let items: [(String, String)]
    let text: Color
    let muted: Color
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(muted)

            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .font(.system(size: 12))
                        .foregroundColor(text)
                    Spacer()
                    Text(item.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(accent.opacity(0.1))
                        )
                }
            }
        }
    }
}

// MARK: - Helper

struct SettingsSection<Content: View>: View {
    let title: String
    let label: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(label)
            content()
        }
    }
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.backgroundColor = AppSettings.shared.theme.sidebarBg
        window.contentView = NSHostingView(rootView: SettingsView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
