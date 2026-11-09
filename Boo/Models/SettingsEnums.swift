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

enum SidebarPosition: Int, CaseIterable {
    case left = 0
    case right = 1

    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

enum WorkspaceBarPosition: Int, CaseIterable {
    case left = 0
    case top = 1
    case right = 2

    var label: String {
        switch self {
        case .left: return "Left"
        case .top: return "Top"
        case .right: return "Right"
        }
    }
}

enum SidebarDensity: Int, CaseIterable {
    case comfortable = 0
    case compact = 1

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

/// How the status bar clock renders the current time.
enum StatusBarClockFormat: Int, CaseIterable {
    case hoursMinutes = 0
    case hoursMinutesSeconds = 1
    case twelveHour = 2
    case dateTime = 3

    var label: String {
        switch self {
        case .hoursMinutes: return "14:05"
        case .hoursMinutesSeconds: return "14:05:09"
        case .twelveHour: return "2:05 PM"
        case .dateTime: return "Fri 30 14:05"
        }
    }

    var dateFormat: String {
        switch self {
        case .hoursMinutes: return "HH:mm"
        case .hoursMinutesSeconds: return "HH:mm:ss"
        case .twelveHour: return "h:mm a"
        case .dateTime: return "EEE d HH:mm"
        }
    }

    /// Whether the clock has to repaint every second rather than every minute.
    var showsSeconds: Bool { self == .hoursMinutesSeconds }

    /// One formatter per format, built once; the clock redraws often.
    /// DateFormatter is thread-safe for formatting.
    private static let formatters: [StatusBarClockFormat: DateFormatter] = Dictionary(
        uniqueKeysWithValues: allCases.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format.dateFormat
            return (format, formatter)
        })

    func string(from date: Date) -> String {
        Self.formatters[self]?.string(from: date) ?? ""
    }
}

/// How the status bar path segment shortens the working directory.
enum StatusBarPathStyle: Int, CaseIterable {
    /// `~/dev/project/src`
    case abbreviated = 0
    /// `src`
    case lastComponent = 1
    /// `~/d/p/src`, fish-style
    case compact = 2

    var label: String {
        switch self {
        case .abbreviated: return "Full"
        case .lastComponent: return "Folder"
        case .compact: return "Compact"
        }
    }
}

enum TabOverflowMode: Int, CaseIterable {
    case scroll = 0
    case wrap = 1
    /// Tabs as a list in a column on the pane's left.
    case vertical = 2

    var label: String {
        switch self {
        case .scroll: return "Scroll"
        case .wrap: return "Wrap"
        case .vertical: return "Vertical"
        }
    }
}

/// When the floating controls in a pane's top-right corner show.
enum PaneControlsVisibility: Int, CaseIterable {
    case hover = 0
    case focused = 1
    case never = 2

    var label: String {
        switch self {
        case .hover: return "On Hover"
        case .focused: return "Focused Pane"
        case .never: return "Never"
        }
    }
}

/// What happens once a terminal recording is stopped.
enum RecordingStopAction: Int, CaseIterable {
    case toast = 0
    case reveal = 1
    case nothing = 2

    var label: String {
        switch self {
        case .toast: return "Show Toast"
        case .reveal: return "Reveal in Finder"
        case .nothing: return "Nothing"
        }
    }
}

enum NewTabCwdMode: Int, CaseIterable {
    case samePath = 0
    case defaultFolder = 1

    var label: String {
        switch self {
        case .samePath: return "Same Path"
        case .defaultFolder: return "Default Folder"
        }
    }
}

/// A string enum offered as a settings picker via `SettingManifest.choices`.
protocol SettingChoice: RawRepresentable, Hashable where RawValue == String {
    var displayName: String { get }
    /// Maps legacy aliases to their canonical case.
    var normalized: Self { get }
    /// Cases shown in the picker (legacy aliases excluded).
    static var visibleCases: [Self] { get }
}

extension SettingChoice {
    var normalized: Self { self }

    static var choices: [PluginManifest.SettingManifest.Choice] {
        visibleCases.map { .init(value: $0.rawValue, label: $0.displayName) }
    }
}

enum MarkdownOpenMode: String, CaseIterable, Codable, SettingChoice {
    case preview = "preview"
    case builtInEditor = "builtInEditor"
    case terminalEditor = "editor"
    case external = "external"
    /// Legacy value — treated as builtInEditor.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .preview: return "Markdown Preview"
        case .builtInEditor: return "Editor"
        case .terminalEditor: return "Terminal Editor"
        case .external: return "External App"
        case .multiContent: return "Editor"  // hidden legacy alias
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: MarkdownOpenMode { self == .multiContent ? .builtInEditor : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [MarkdownOpenMode] { [.preview, .builtInEditor, .terminalEditor, .external] }
}

enum ImageOpenMode: String, CaseIterable, Codable, SettingChoice {
    case imageViewer = "imageViewer"
    case kitty = "kitty"
    case external = "external"
    /// Legacy value — treated as imageViewer.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .imageViewer: return "Image Viewer"
        case .kitty: return "Inline (Kitty)"
        case .external: return "External App"
        case .multiContent: return "Image Viewer"
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: ImageOpenMode { self == .multiContent ? .imageViewer : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [ImageOpenMode] { [.imageViewer, .kitty, .external] }
}

enum TextOpenMode: String, CaseIterable, Codable, SettingChoice {
    case editor = "editor"
    case terminalEditor = "terminalEditor"
    case external = "external"
    /// Legacy value — treated as editor.
    case multiContent = "multiContent"

    var displayName: String {
        switch self {
        case .editor: return "Editor"
        case .terminalEditor: return "Terminal Editor"
        case .external: return "External App"
        case .multiContent: return "Editor"
        }
    }

    /// Maps legacy cases to their canonical replacement for UI display.
    var normalized: TextOpenMode { self == .multiContent ? .editor : self }

    /// Cases shown in the UI picker (excludes the legacy multiContent alias).
    static var visibleCases: [TextOpenMode] { [.editor, .terminalEditor, .external] }
}

enum LinkOpenMode: String, CaseIterable, Codable, SettingChoice {
    static var visibleCases: [LinkOpenMode] { allCases }

    case browserTab = "browserTab"
    case externalBrowser = "externalBrowser"

    var displayName: String {
        switch self {
        case .browserTab: return "Browser Tab"
        case .externalBrowser: return "External Browser"
        }
    }
}

enum SidebarTabBarPosition: String, CaseIterable {
    case top
    case bottom

    var label: String { rawValue.capitalized }
}

/// Identifies a sidebar tab. Built-in tabs use well-known IDs; plugin-contributed tabs
/// use the plugin's ID as their identifier.
struct SidebarTabID: Hashable, Codable, CustomStringConvertible {
    let id: String

    static let explorer = SidebarTabID("explorer")
    static let search = SidebarTabID("search")

    init(_ id: String) { self.id = id }

    var description: String { id }

    // MARK: - Codable
    init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

// MARK: - Editor option values

/// Raw values are stored in settings and sent to the editor page.
enum EditorRenderWhitespace: String, CaseIterable, Sendable {
    case none, boundary, selection, trailing, all

    var displayName: String {
        switch self {
        case .none: return "Never"
        case .boundary: return "Between words"
        case .selection: return "In selection"
        case .trailing: return "Trailing"
        case .all: return "Always"
        }
    }
}

/// Raw values are stored in settings and sent to the editor page.
enum EditorCursorStyle: String, CaseIterable, Sendable {
    case line, block, underline

    var displayName: String {
        switch self {
        case .line: return "Bar"
        case .block: return "Block"
        case .underline: return "Underline"
        }
    }
}

enum EditorAutosave: String, CaseIterable, Sendable {
    case off, afterDelay, onFocusChange

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .afterDelay: return "After a short delay"
        case .onFocusChange: return "When the editor loses focus"
        }
    }
}
