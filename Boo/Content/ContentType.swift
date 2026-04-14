import Cocoa

/// Identifies the type of content a tab can display.
enum ContentType: String, Codable, CaseIterable {
    case terminal
    case browser
    case editor
    case imageViewer
    case markdownPreview
    case pluginView

    /// SF Symbol name for this content type.
    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .editor: return "doc.text"
        case .imageViewer: return "photo"
        case .markdownPreview: return "doc.richtext"
        case .pluginView: return "puzzlepiece"
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
        case .pluginView: return "Panel"
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

    /// Whether this content type's state can be persisted across sessions.
    var isPersistable: Bool {
        switch self {
        case .pluginView: return false
        default: return true
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
        case .pluginView: return "Panel"
        }
    }

    /// Blank URL for browser tabs.
    static let blankURL = URL(string: "about:blank")!

    /// URL for new browser tabs — uses the configured home page, falling back to blank.
    static var newTabURL: URL {
        let raw = AppSettings.shared.browserHomePage.trimmingCharacters(in: .whitespaces)
        return URL(string: raw) ?? blankURL
    }

    // MARK: - Tab Creation

    /// Content types that users can create directly via UI (dropdown, context menu).
    static var creatableTypes: [ContentType] { [.terminal, .browser] }

    // MARK: - File Association

    /// Image file extensions that open in image viewer.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif",
        "bmp", "tiff", "tif", "ico", "svg"
    ]

    /// Markdown file extensions that open in markdown preview.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]

    /// HTML file extensions — can open in browser tab or built-in editor.
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// PDF file extensions — can open in browser tab (WKWebView renders natively).
    static let pdfExtensions: Set<String> = ["pdf"]

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
        if pdfExtensions.contains(ext) {
            return .browser
        }
        return nil
    }

    /// Check if a file extension is a markdown file.
    static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    /// Built-in file patterns — always treated as internal editor files regardless of user setting.
    /// Supports plain extensions (`swift`), full filenames (`.gitignore`),
    /// globs (`*.log`, `.env*`), and brace groups (`*.{ts,tsx}`).
    static let builtInEditorFilePatterns =
        "swift,m,h,c,cpp,*.{js,ts,jsx,tsx},py,rb,go,rs,java,kt,sh,bash,zsh,fish,"
        + "html,css,scss,sass,less,vue,svelte,json,yaml,yml,toml,xml,plist,"
        + "txt,log,conf,cfg,ini,env,.gitignore,.gitmodules,.gitattributes,"
        + "dockerfile,makefile,.editorconfig,.npmrc,.yarnrc,.nvmrc,.env*"

    /// Expand a single pattern containing a brace group `{a,b,c}` into multiple patterns.
    /// Only one brace group per pattern is supported. `*.{ts,tsx}` → `["*.ts", "*.tsx"]`.
    static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
            let close = pattern[open...].firstIndex(of: "}")
        else { return [pattern] }
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let alts = pattern[pattern.index(after: open)..<close].split(separator: ",")
        return alts.map { prefix + $0 + suffix }
    }

    // Cache compiled regexes — glob patterns are finite and repeated on every file click.
    @MainActor private static var globRegexCache: [String: NSRegularExpression] = [:]

    /// Returns true if `filename` (lowercased) matches the glob `pattern`.
    /// Supports `*` wildcard and brace groups `{a,b}`.
    @MainActor
    static func globMatches(pattern: String, filename: String) -> Bool {
        let expanded = expandBraces(pattern)
        if expanded.count > 1 { return expanded.contains { globMatches(pattern: $0, filename: filename) } }

        guard pattern.contains("*") else { return pattern == filename }
        var regexStr = "^"
        for ch in pattern {
            switch ch {
            case "*": regexStr += ".*"
            case ".", "+", "?", "^", "$", "[", "]", "(", ")", "|", "\\": regexStr += "\\\(ch)"
            default: regexStr += String(ch)
            }
        }
        regexStr += "$"
        let compiled: NSRegularExpression
        if let cached = globRegexCache[regexStr] {
            compiled = cached
        } else if let fresh = try? NSRegularExpression(pattern: regexStr) {
            globRegexCache[regexStr] = fresh
            compiled = fresh
        } else {
            return false
        }
        return compiled.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
    }

    /// Returns true if `filename` (lowercased) should open in the built-in editor.
    /// Checks the built-in floor first, then the user-stored setting.
    /// Old key "editorExtensions" is read as fallback for migration.
    /// Split a comma-delimited pattern string, treating commas inside `{...}` as literals.
    /// `"swift,*.{js,ts},py"` → `["swift", "*.{js,ts}", "py"]`
    static func splitPatterns(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in raw {
            switch ch {
            case "{":
                depth += 1
                current.append(ch)
            case "}":
                depth -= 1
                current.append(ch)
            case "," where depth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespaces).lowercased()
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            default: current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    @MainActor
    static func isEditorFilePattern(filename: String) -> Bool {
        let lower = filename.lowercased()
        func matchesPatterns(_ raw: String) -> Bool {
            let patterns = splitPatterns(raw)
            let ext = (lower as NSString).pathExtension
            return patterns.contains { pattern in
                if pattern.contains("*") || pattern.contains("{") {
                    return globMatches(pattern: pattern, filename: lower)
                }
                return pattern == lower || pattern == ext
            }
        }

        if matchesPatterns(builtInEditorFilePatterns) { return true }

        let stored = AppSettings.shared.pluginString(
            "file-tree-local", "editorFilePatterns",
            default: AppSettings.shared.pluginString(
                "file-tree-local", "editorExtensions",
                default: builtInEditorFilePatterns
            )
        )
        // Skip re-parsing when user hasn't customised the setting
        if stored == builtInEditorFilePatterns { return false }
        return matchesPatterns(stored)
    }
}
