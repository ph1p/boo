import Foundation

/// Protocol for content-type-specific state that can be persisted per tab.
protocol ContentStateProtocol: Codable {
    var contentType: ContentType { get }
    /// Runtime display title — not persisted, regenerated after restore.
    var title: String { get set }
}

/// Type-erased wrapper for ContentStateProtocol to enable storage in TabState.
/// Uses a discriminated union approach for Codable conformance.
enum ContentState: Codable, Sendable {
    case terminal(TerminalContentState)
    case browser(BrowserContentState)
    case editor(EditorContentState)
    case imageViewer(ImageViewerContentState)
    case pdfViewer(PDFViewerContentState)
    case markdownPreview(MarkdownPreviewContentState)
    /// Plugin-owned view tab. State is ephemeral — not persisted across sessions.
    case pluginView(PluginViewContentState)
    case castPlayer(CastPlayerContentState)

    var contentType: ContentType {
        switch self {
        case .terminal: return .terminal
        case .browser: return .browser
        case .editor: return .editor
        case .imageViewer: return .imageViewer
        case .pdfViewer: return .pdfViewer
        case .markdownPreview: return .markdownPreview
        case .pluginView: return .pluginView
        case .castPlayer: return .castPlayer
        }
    }

    var title: String {
        get {
            switch self {
            case .terminal(let s): return s.title
            case .browser(let s): return s.title
            case .editor(let s): return s.title
            case .imageViewer(let s): return s.title
            case .pdfViewer(let s): return s.title
            case .markdownPreview(let s): return s.title
            case .pluginView(let s): return s.title
            case .castPlayer(let s): return s.title
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
            case .pdfViewer(var s):
                s.title = newValue
                self = .pdfViewer(s)
            case .markdownPreview(var s):
                s.title = newValue
                self = .markdownPreview(s)
            case .pluginView(var s):
                s.title = newValue
                self = .pluginView(s)
            case .castPlayer(var s):
                s.title = newValue
                self = .castPlayer(s)
            }
        }
    }

    /// The local file this content shows (a `file://` page for a browser), or nil.
    var filePath: String? {
        let path: String?
        switch self {
        case .editor(let s): path = s.filePath
        case .imageViewer(let s): path = s.filePath
        case .pdfViewer(let s): path = s.filePath
        case .markdownPreview(let s): path = s.filePath
        case .castPlayer(let s): path = s.filePath
        case .browser(let s): path = s.url.isFileURL ? s.url.path : nil
        case .terminal, .pluginView: path = nil
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// Folder of `filePath`, used as the tab's working directory.
    var fileDirectory: String? {
        filePath.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// State for a `type` tab that shows the file at `path`, titled with its
    /// name. nil for types that do not show a file.
    static func forFile(_ path: String, as type: ContentType) -> ContentState? {
        let title = (path as NSString).lastPathComponent
        switch type {
        case .editor: return .editor(EditorContentState(title: title, filePath: path))
        case .imageViewer: return .imageViewer(ImageViewerContentState(title: title, filePath: path))
        case .pdfViewer: return .pdfViewer(PDFViewerContentState(title: title, filePath: path))
        case .markdownPreview: return .markdownPreview(MarkdownPreviewContentState(title: title, filePath: path))
        case .castPlayer: return .castPlayer(CastPlayerContentState(title: title, filePath: path))
        case .terminal, .browser, .pluginView: return nil
        }
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
struct TerminalContentState: ContentStateProtocol, Codable, Sendable {
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

struct BrowserContentState: ContentStateProtocol, Codable, Sendable {
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

struct EditorContentState: ContentStateProtocol, Codable, Sendable {
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

struct ImageViewerContentState: ContentStateProtocol, Codable, Sendable {
    var contentType: ContentType { .imageViewer }
    var title: String = ""
    var filePath: String
    var zoom: CGFloat = 1.0
}

// MARK: - Cast Player State

struct CastPlayerContentState: ContentStateProtocol, Codable, Sendable {
    var contentType: ContentType { .castPlayer }
    var title: String = ""
    var filePath: String

    enum CodingKeys: String, CodingKey {
        case title, filePath
    }

    init(title: String, filePath: String) {
        self.title = title
        self.filePath = filePath
    }
}

// MARK: - Markdown Preview State

struct MarkdownPreviewContentState: ContentStateProtocol, Codable, Sendable {
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
struct PluginViewContentState: ContentStateProtocol, Codable, Sendable {
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

struct PDFViewerContentState: ContentStateProtocol, Codable, Sendable {
    var contentType: ContentType { .pdfViewer }
    var title: String = ""
    var filePath: String
    /// Zero-based index of the page shown at the top of the view.
    var pageIndex: Int = 0
    /// Scale factor; 0 means "fit to width".
    var zoom: CGFloat = 0
}
