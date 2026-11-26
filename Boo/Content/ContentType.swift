import Cocoa
import UniformTypeIdentifiers

/// Identifies the type of content a tab can display.
enum ContentType: String, Codable, CaseIterable {
    case terminal
    case browser
    case editor
    case imageViewer
    case pdfViewer
    case markdownPreview
    case pluginView
    case castPlayer

    /// SF Symbol name for this content type.
    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .editor: return "doc.text"
        case .imageViewer: return "photo"
        case .pdfViewer: return "doc.text.image"
        case .markdownPreview: return "doc.richtext"
        case .pluginView: return "puzzlepiece"
        case .castPlayer: return "play.rectangle"
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
        case .pdfViewer: return "PDF"
        case .markdownPreview: return "Markdown"
        case .pluginView: return "Panel"
        case .castPlayer: return "Recording"
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
        case .pdfViewer: return "PDF"
        case .markdownPreview: return "Markdown"
        case .pluginView: return "Panel"
        case .castPlayer: return "Recording"
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
    /// SVG is intentionally excluded — it is text-based and can be opened in the editor
    /// if the user adds "svg" to their editor file patterns.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif",
        "bmp", "tiff", "tif", "ico"
    ]

    /// Markdown file extensions that open in markdown preview.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]

    /// HTML file extensions — can open in browser tab or built-in editor.
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// PDF file extensions — open in the PDF viewer.
    static let pdfExtensions: Set<String> = ["pdf"]

    /// asciicast recordings — open in the cast player.
    static let castExtensions: Set<String> = ["cast"]

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
            return .pdfViewer
        }
        if castExtensions.contains(ext) {
            return .castPlayer
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
        "swift,m,mm,h,hh,hpp,c,cc,cpp,cxx,cs,*.{js,ts,jsx,tsx,mjs,cjs,mts,cts},py,rb,go,rs,java,kt,kts,"
        + "scala,groovy,gradle,php,pl,pm,lua,r,dart,zig,nix,ex,exs,erl,hs,ml,clj,"
        + "sh,bash,zsh,fish,ps1,bat,cmd,sql,graphql,gql,proto,tf,hcl,"
        + "html,css,scss,sass,less,vue,svelte,astro,mdx,json,jsonc,json5,jsonl,ndjson,"
        + "yaml,yml,toml,xml,plist,properties,lock,csv,tsv,diff,patch,rst,adoc,tex,"
        + "txt,log,conf,cfg,ini,env,.gitignore,.gitmodules,.gitattributes,"
        + "dockerfile,makefile,justfile,procfile,gemfile,rakefile,podfile,brewfile,vagrantfile,"
        + "license*,licence*,copying*,notice*,authors*,contributors*,readme*,changelog*,"
        + ".editorconfig,.npmrc,.yarnrc,.nvmrc,.env*"

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

    /// Returns true if the file at `path` should open in the built-in editor: it
    /// matches an editor pattern, or it has no extension or one that names a text
    /// type, and its first bytes are text. This catches scripts, `LICENSE` and
    /// other extensionless files without opening binaries.
    @MainActor
    static func opensInEditor(path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        if isEditorFilePattern(filename: filename) { return true }
        return mayBeText(extension: (filename as NSString).pathExtension) && isTextFile(atPath: path)
    }

    /// False for extensions the system knows as a non-text type (archives, media,
    /// documents), so those are never sniffed. Images are excluded even when
    /// text-based (SVG), matching `imageExtensions`.
    static func mayBeText(extension ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return true }
        if type.conforms(to: .image) || type.conforms(to: .rtf) { return false }
        let textTypes: [UTType] = [.plainText, .sourceCode, .script, .json, .xml, .yaml, .propertyList]
        return textTypes.contains { type.conforms(to: $0) }
    }

    /// Bytes sniffed by `isTextFile(atPath:)`.
    static let textSniffLength = 8192

    /// Returns true if the regular file at `path` looks like text: empty, UTF-16
    /// with a byte order mark, or no NUL byte and almost no control characters in
    /// its first `textSniffLength` bytes. Matches what the editor can decode.
    static func isTextFile(atPath path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        // Only regular files: reading a FIFO or device would block or never end.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let handle = FileHandle(forReadingAtPath: resolved)
        else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textSniffLength), !data.isEmpty else { return true }
        return looksLikeText(data)
    }

    static func looksLikeText(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return true }
        var control = 0
        for byte in data {
            if byte == 0 { return false }
            // Tab, LF, FF, CR and ESC (ANSI colors in logs) are fine in text.
            if byte < 0x20, ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(byte) { control += 1 }
        }
        return control * 100 <= data.count
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
