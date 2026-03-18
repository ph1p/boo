import Cocoa

enum CursorStyle: Int, CaseIterable {
    case block = 0
    case beam = 1
    case underline = 2
    case blockOutline = 3

    var label: String {
        switch self {
        case .block: return "Block"
        case .beam: return "Beam"
        case .underline: return "Underline"
        case .blockOutline: return "Outline"
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("ExtermSettingsChanged")
}

final class AppSettings {
    static let shared = AppSettings()

    // MARK: - Keys

    private enum K {
        static let themeName = "themeName"
        static let cursorStyle = "cursorStyle"
        static let fontSize = "fontSize"
        static let fontName = "fontName"
        static let showExplorerHeader = "showExplorerHeader"
        static let showHiddenFiles = "showHiddenFiles"
        static let explorerIconsEnabled = "explorerIconsEnabled"
        static let explorerFontSize = "explorerFontSize"
        static let explorerFontName = "explorerFontName"
        static let statusBarShowPath = "statusBarShowPath"
        static let statusBarShowGitBranch = "statusBarShowGitBranch"
        static let statusBarShowTime = "statusBarShowTime"
        static let statusBarShowPaneInfo = "statusBarShowPaneInfo"
        static let statusBarShowShell = "statusBarShowShell"
    }

    /// Bool from UserDefaults with a custom default (since .bool returns false for unset keys).
    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
    }

    private func set(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        saveToFile()
        notify()
    }

    // MARK: - Theme

    var themeName: String {
        get { UserDefaults.standard.string(forKey: K.themeName) ?? "Default Dark" }
        set { set(newValue, forKey: K.themeName) }
    }

    var theme: TerminalTheme {
        TerminalTheme.themes.first { $0.name == themeName } ?? .defaultDark
    }

    // MARK: - Terminal

    var cursorStyle: CursorStyle {
        get { CursorStyle(rawValue: UserDefaults.standard.integer(forKey: K.cursorStyle)) ?? .block }
        set { set(newValue.rawValue, forKey: K.cursorStyle) }
    }

    var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.fontSize)
            return v > 0 ? CGFloat(v) : 14.0
        }
        set { set(Double(newValue), forKey: K.fontSize) }
    }

    var fontName: String {
        get { UserDefaults.standard.string(forKey: K.fontName) ?? "SF Mono" }
        set { set(newValue, forKey: K.fontName) }
    }

    // MARK: - Explorer

    var showExplorerHeader: Bool {
        get { bool(K.showExplorerHeader, default: true) }
        set { set(newValue, forKey: K.showExplorerHeader) }
    }

    var showHiddenFiles: Bool {
        get { UserDefaults.standard.bool(forKey: K.showHiddenFiles) }
        set { set(newValue, forKey: K.showHiddenFiles) }
    }

    var explorerIconsEnabled: Bool {
        get { bool(K.explorerIconsEnabled, default: true) }
        set { set(newValue, forKey: K.explorerIconsEnabled) }
    }

    var explorerFontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.explorerFontSize)
            return v > 0 ? CGFloat(v) : 12.0
        }
        set { set(Double(newValue), forKey: K.explorerFontSize) }
    }

    var explorerFontName: String {
        get { UserDefaults.standard.string(forKey: K.explorerFontName) ?? "" }
        set { set(newValue, forKey: K.explorerFontName) }
    }

    // MARK: - Status Bar

    var statusBarShowPath: Bool {
        get { bool(K.statusBarShowPath, default: true) }
        set { set(newValue, forKey: K.statusBarShowPath) }
    }

    var statusBarShowGitBranch: Bool {
        get { bool(K.statusBarShowGitBranch, default: true) }
        set { set(newValue, forKey: K.statusBarShowGitBranch) }
    }

    var statusBarShowTime: Bool {
        get { bool(K.statusBarShowTime, default: true) }
        set { set(newValue, forKey: K.statusBarShowTime) }
    }

    var statusBarShowPaneInfo: Bool {
        get { bool(K.statusBarShowPaneInfo, default: true) }
        set { set(newValue, forKey: K.statusBarShowPaneInfo) }
    }

    var statusBarShowShell: Bool {
        get { bool(K.statusBarShowShell, default: false) }
        set { set(newValue, forKey: K.statusBarShowShell) }
    }

    // MARK: - Font Resolution

    func resolvedFont() -> NSFont {
        if let font = NSFont(name: fontName, size: fontSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var availableMonospaceFonts: [String] {
        let fm = NSFontManager.shared
        var fonts: [String] = ["SF Mono"]
        for family in fm.availableFontFamilies {
            if let members = fm.availableMembers(ofFontFamily: family),
               let first = members.first,
               let traits = first[3] as? UInt,
               (traits & UInt(NSFontTraitMask.fixedPitchFontMask.rawValue)) != 0 {
                fonts.append(family)
            }
        }
        let knownMono = ["Menlo", "Monaco", "Courier", "Courier New", "Fira Code", "JetBrains Mono", "Hack", "Source Code Pro", "Inconsolata"]
        for name in knownMono {
            if !fonts.contains(name), NSFont(name: name, size: 14) != nil {
                fonts.append(name)
            }
        }
        return fonts.sorted()
    }

    static var availableSystemFonts: [String] {
        var result = ["System Default"]
        result.append(contentsOf: NSFontManager.shared.availableFontFamilies.sorted())
        return result
    }

    private func notify() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    // MARK: - File Persistence (~/.exterm/settings.json)

    private func saveToFile() {
        let dict: [String: Any] = [
            K.themeName: themeName,
            K.cursorStyle: cursorStyle.rawValue,
            K.fontSize: Double(fontSize),
            K.fontName: fontName,
            K.showExplorerHeader: showExplorerHeader,
            K.showHiddenFiles: showHiddenFiles,
            K.explorerIconsEnabled: explorerIconsEnabled,
            K.explorerFontSize: Double(explorerFontSize),
            K.explorerFontName: explorerFontName,
            K.statusBarShowPath: statusBarShowPath,
            K.statusBarShowGitBranch: statusBarShowGitBranch,
            K.statusBarShowTime: statusBarShowTime,
            K.statusBarShowPaneInfo: statusBarShowPaneInfo,
            K.statusBarShowShell: statusBarShowShell,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ExtermPaths.settingsFile))
        }
    }

    private func loadFromFile() {
        let path = ExtermPaths.settingsFile
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Only load values that aren't already in UserDefaults (first launch migration)
        for (key, value) in dict {
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private init() {
        // On first launch, load settings from ~/.exterm/settings.json if it exists
        loadFromFile()
        // Ensure the config directory exists
        _ = ExtermPaths.configDir
    }
}

/// Observable wrapper so SwiftUI views re-render when settings change.
final class SettingsObserver: ObservableObject {
    @Published var revision: Int = 0
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revision += 1
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
