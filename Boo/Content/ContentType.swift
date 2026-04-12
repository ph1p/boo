import Cocoa

/// Identifies the type of content a tab can display.
enum ContentType: String, Codable, CaseIterable {
    case terminal
    case browser
    case editor
    case imageViewer
    case markdownPreview

    /// SF Symbol name for this content type.
    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .editor: return "doc.text"
        case .imageViewer: return "photo"
        case .markdownPreview: return "doc.richtext"
        }
    }

    /// Icon for tab bar display.
    var icon: NSImage {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: displayName)
            ?? NSImage(named: NSImage.cautionName)!
    }

    /// Human-readable name for accessibility and UI.
    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .editor: return "Editor"
        case .imageViewer: return "Image"
        case .markdownPreview: return "Markdown"
        }
    }

    /// Whether this content type supports the plugin sidebar.
    /// Terminal has full plugin support; others show placeholder for now.
    var supportsPlugins: Bool {
        switch self {
        case .terminal: return true
        default: return false
        }
    }

    /// Default title for new tabs of this type.
    var defaultTabTitle: String {
        switch self {
        case .terminal: return "shell"
        case .browser: return "New Tab"
        case .editor: return "Untitled"
        case .imageViewer: return "Image"
        case .markdownPreview: return "Markdown"
        }
    }

    /// Blank URL for browser tabs.
    static let blankURL = URL(string: "about:blank")!

    // MARK: - Tab Creation

    /// Content types that users can create directly via UI (dropdown, context menu).
    static var creatableTypes: [ContentType] { [.terminal, .browser] }

    // MARK: - File Association

    /// Image file extensions that open in image viewer.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif",
        "bmp", "tiff", "tif", "ico", "svg"
    ]

    /// Markdown file extensions that open in markdown preview.
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd"
    ]

    /// Resolve content type for a file path based on extension.
    /// Returns nil for files that should fall back to external/editor handling.
    static func forFile(_ path: String) -> ContentType? {
        let ext = (path as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) {
            return .markdownPreview
        }
        if imageExtensions.contains(ext) {
            return .imageViewer
        }
        return nil
    }

    /// Check if a file extension is a markdown file.
    static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }
}
