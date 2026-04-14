import Foundation

/// Detects content type from user input (URLs, file paths, etc.).
enum ContentTypeDetector {
    /// Detect content type from a string input.
    /// Returns nil if no specific content type is detected (defaults to terminal).
    static func detect(from input: String) -> ContentType? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URL detection
        if let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            return .browser
        }

        // File path detection
        let path = (trimmed as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        // Check if it's a file that exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        // Don't auto-detect directories
        guard !isDirectory.boolValue else { return nil }

        let ext = (path as NSString).pathExtension.lowercased()

        // Image files
        if ContentType.imageExtensions.contains(ext) {
            return .imageViewer
        }

        // Markdown files
        if ContentType.markdownExtensions.contains(ext) {
            return .markdownPreview
        }

        // Don't auto-detect editor (too generic — most files would match)
        return nil
    }

    /// Detect content type from a URL.
    static func detect(from url: URL) -> ContentType? {
        // Web URLs
        if let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            return .browser
        }

        // File URLs
        if url.isFileURL {
            return detect(from: url.path)
        }

        return nil
    }

    /// Check if a string looks like a URL.
    static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Explicit scheme
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }

        // Common URL patterns without scheme
        let urlPatterns = [
            "www.",
            "localhost"
        ]

        for pattern in urlPatterns {
            if trimmed.lowercased().hasPrefix(pattern) {
                return true
            }
        }

        // Domain-like pattern: word.word (e.g., example.com)
        // But exclude common file extensions
        let ext = (trimmed as NSString).pathExtension.lowercased()
        let fileExtensions: Set<String> = [
            "txt", "md", "json", "xml", "html", "css", "js", "ts", "swift", "py", "rb", "go",
            "rs", "c", "cpp", "h", "hpp", "java", "kt", "sh", "bash", "zsh", "yml", "yaml",
            "toml", "ini", "cfg", "conf", "log", "csv", "tsv", "sql", "graphql"
        ]
        if fileExtensions.contains(ext) {
            return false
        }

        let domainRegex = try? NSRegularExpression(
            pattern: "^[a-zA-Z0-9][a-zA-Z0-9-]*\\.[a-zA-Z]{2,}",
            options: []
        )
        if let regex = domainRegex,
            regex.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: trimmed.utf16.count)
            ) != nil
        {
            return true
        }

        return false
    }

    /// Normalize a URL-like string to a proper URL.
    /// Adds https:// scheme if missing.
    static func normalizeURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already has scheme
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        // Add https:// for domain-like strings
        if looksLikeURL(trimmed) {
            return URL(string: "https://" + trimmed)
        }

        return nil
    }
}
