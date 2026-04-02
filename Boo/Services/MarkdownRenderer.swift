import CIronmark

enum MarkdownRenderer {
    /// Convert a Markdown string to an HTML string using ironmark.
    static func renderHTML(from markdown: String) -> String {
        guard let cResult = ironmark_parse(markdown) else { return "" }
        let html = String(cString: cResult)
        ironmark_free(cResult)
        return html
    }
}
