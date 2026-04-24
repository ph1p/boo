import Foundation

/// Protocol for content-type-specific state that can be persisted per tab.
protocol ContentStateProtocol: Codable {
    var contentType: ContentType { get }
    /// Runtime display title — not persisted, regenerated after restore.
    var title: String { get set }
}

/// Type-erased wrapper for ContentStateProtocol to enable storage in TabState.
/// Uses a discriminated union approach for Codable conformance.
enum ContentState: Codable {
    case terminal(TerminalContentState)
    case browser(BrowserContentState)
    case editor(EditorContentState)
    case imageViewer(ImageViewerContentState)
    case markdownPreview(MarkdownPreviewContentState)
    /// Plugin-owned view tab. State is ephemeral — not persisted across sessions.
    case pluginView(PluginViewContentState)

    var contentType: ContentType {
        switch self {
        case .terminal: return .terminal
        case .browser: return .browser
        case .editor: return .editor
        case .imageViewer: return .imageViewer
        case .markdownPreview: return .markdownPreview
        case .pluginView: return .pluginView
        }
    }

    var title: String {
        get {
            switch self {
            case .terminal(let s): return s.title
            case .browser(let s): return s.title
            case .editor(let s): return s.title
            case .imageViewer(let s): return s.title
            case .markdownPreview(let s): return s.title
            case .pluginView(let s): return s.title
            }
        }
        set {
            switch self {
            case .terminal(var s):
                s.title = newValue
                self = .terminal(s)
            case .browser(var s):
                s.title = newValue
                self = .browser(s)
            case .editor(var s):
                s.title = newValue
                self = .editor(s)
            case .imageViewer(var s):
                s.title = newValue
                self = .imageViewer(s)
            case .markdownPreview(var s):
                s.title = newValue
                self = .markdownPreview(s)
            case .pluginView(var s):
                s.title = newValue
                self = .pluginView(s)
            }
        }
    }

    /// Access terminal-specific state. Returns nil for non-terminal content.
    var asTerminal: TerminalContentState? {
        if case .terminal(let s) = self { return s }
        return nil
    }

    /// Mutate terminal-specific state. No-op for non-terminal content.
    mutating func updateTerminal(_ transform: (inout TerminalContentState) -> Void) {
        if case .terminal(var s) = self {
            transform(&s)
            self = .terminal(s)
        }
    }
}

// MARK: - Terminal State

/// Terminal-specific content state.
/// Note: remoteSession is not included here because it's managed by TabState/TerminalBridge
/// and RemoteSessionType is not Codable. Terminal state restoration uses TabState fields.
struct TerminalContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .terminal }
    var title: String = ""
    var workingDirectory: String
    var shellPID: pid_t = 0
    var foregroundProcess: String = ""

    enum CodingKeys: String, CodingKey {
        case workingDirectory
    }

    init(
        title: String = "",
        workingDirectory: String = "~",
        shellPID: pid_t = 0,
        foregroundProcess: String = ""
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.shellPID = shellPID
        self.foregroundProcess = foregroundProcess
    }
}

// MARK: - Browser State

struct BrowserContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .browser }
    var title: String = ""
    var url: URL
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    enum CodingKeys: String, CodingKey {
        case title, url
    }

    init(
        title: String = "New Tab",
        url: URL = URL(string: "about:blank")!,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.title = title
        self.url = url
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

// MARK: - Editor State

struct EditorContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .editor }
    var title: String = ""
    var filePath: String?
    var isDirty: Bool = false
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    enum CodingKeys: String, CodingKey {
        case title, filePath, isDirty, cursorLine, cursorColumn
    }

    init(
        title: String = "Untitled",
        filePath: String? = nil,
        isDirty: Bool = false,
        cursorLine: Int = 1,
        cursorColumn: Int = 1
    ) {
        self.title = title
        self.filePath = filePath
        self.isDirty = isDirty
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
    }
}

// MARK: - Image Viewer State

struct ImageViewerContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .imageViewer }
    var title: String = ""
    var filePath: String
    var zoom: CGFloat = 1.0

    enum CodingKeys: String, CodingKey {
        case title, filePath, zoom
    }

    init(title: String, filePath: String, zoom: CGFloat = 1.0) {
        self.title = title
        self.filePath = filePath
        self.zoom = zoom
    }
}

// MARK: - Markdown Preview State

struct MarkdownPreviewContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .markdownPreview }
    var title: String = ""
    var filePath: String
    var scrollPosition: CGFloat = 0

    enum CodingKeys: String, CodingKey {
        case title, filePath, scrollPosition
    }

    init(title: String, filePath: String, scrollPosition: CGFloat = 0) {
        self.title = title
        self.filePath = filePath
        self.scrollPosition = scrollPosition
    }
}

// MARK: - Plugin View State

/// Minimal state for a plugin-owned view tab.
/// The view itself is not persisted — only the display title and icon symbol.
struct PluginViewContentState: ContentStateProtocol, Codable {
    var contentType: ContentType { .pluginView }
    var title: String = ""
    var iconSymbol: String

    enum CodingKeys: String, CodingKey {
        case iconSymbol
    }

    init(title: String, iconSymbol: String = "puzzlepiece") {
        self.title = title
        self.iconSymbol = iconSymbol
    }
}
