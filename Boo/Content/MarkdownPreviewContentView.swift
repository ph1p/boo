import Cocoa
import WebKit

/// ContentViewProtocol implementation for markdown preview tabs.
/// Placeholder implementation for Phase 3.
final class MarkdownPreviewContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .markdownPreview

    private var webView: WKWebView?
    private var filePath: String?
    private var currentTitle: String = "Markdown"
    private var scrollPosition: CGFloat = 0

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    // MARK: - Init

    init(filePath: String?) {
        self.filePath = filePath
        if let path = filePath {
            self.currentTitle = (path as NSString).lastPathComponent
        }
        super.init(frame: .zero)
        wantsLayer = true
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: bounds, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        webView = wv

        if let path = filePath {
            loadMarkdown(at: path)
        } else {
            showPlaceholder()
        }
    }

    private func loadMarkdown(at path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            showPlaceholder()
            return
        }
        renderMarkdown(content)
    }

    private func renderMarkdown(_ markdown: String) {
        let renderedHTML = MarkdownRenderer.renderHTML(from: markdown)
        let theme = AppSettings.shared.theme
        let bgColor = theme.background.hexString
        let textColor = theme.foreground.hexString
        let mutedColor = theme.chromeMuted.hexString

        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <style>
                    :root {
                        color-scheme: dark light;
                    }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                        font-size: 14px;
                        line-height: 1.6;
                        padding: 24px;
                        max-width: 900px;
                        margin: 0 auto;
                        background: \(bgColor);
                        color: \(textColor);
                    }
                    h1, h2, h3, h4, h5, h6 {
                        margin-top: 24px;
                        margin-bottom: 16px;
                        font-weight: 600;
                        line-height: 1.25;
                    }
                    h1 { font-size: 2em; border-bottom: 1px solid \(mutedColor); padding-bottom: 0.3em; }
                    h2 { font-size: 1.5em; border-bottom: 1px solid \(mutedColor); padding-bottom: 0.3em; }
                    h3 { font-size: 1.25em; }
                    p { margin-top: 0; margin-bottom: 16px; }
                    a { color: #58a6ff; text-decoration: none; }
                    a:hover { text-decoration: underline; }
                    pre {
                        background: rgba(128, 128, 128, 0.1);
                        padding: 16px;
                        border-radius: 6px;
                        overflow-x: auto;
                        font-size: 13px;
                    }
                    code {
                        font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
                        font-size: 0.9em;
                    }
                    :not(pre) > code {
                        background: rgba(128, 128, 128, 0.15);
                        padding: 0.2em 0.4em;
                        border-radius: 4px;
                    }
                    blockquote {
                        margin: 0;
                        padding: 0 1em;
                        border-left: 4px solid \(mutedColor);
                        color: \(mutedColor);
                    }
                    ul, ol { padding-left: 2em; }
                    li { margin-bottom: 4px; }
                    hr {
                        height: 1px;
                        border: none;
                        background: \(mutedColor);
                        margin: 24px 0;
                    }
                    table {
                        border-collapse: collapse;
                        width: 100%;
                        margin-bottom: 16px;
                    }
                    th, td {
                        padding: 8px 12px;
                        border: 1px solid \(mutedColor);
                    }
                    th { background: rgba(128, 128, 128, 0.1); }
                    img { max-width: 100%; }
                    .task-list-item { list-style-type: none; }
                    .task-list-item input { margin-right: 8px; }
                </style>
            </head>
            <body>
                \(renderedHTML)
            </body>
            </html>
            """
        webView?.loadHTMLString(html, baseURL: URL(fileURLWithPath: filePath ?? ""))
    }

    private func showPlaceholder() {
        let theme = AppSettings.shared.theme
        let bgColor = theme.background.hexString
        let mutedColor = theme.chromeMuted.hexString
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <style>
                    body {
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        height: 100vh;
                        margin: 0;
                        background: \(bgColor);
                        color: \(mutedColor);
                        font-family: -apple-system, sans-serif;
                    }
                </style>
            </head>
            <body>
                <p>No markdown file loaded</p>
            </body>
            </html>
            """
        webView?.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(webView)
        onFocused?()
    }

    func deactivate() {
        // WebView stays alive
    }

    func cleanup() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    func saveState() -> ContentState {
        .markdownPreview(
            MarkdownPreviewContentState(
                title: currentTitle,
                filePath: filePath ?? "",
                scrollPosition: scrollPosition
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .markdownPreview(let markdownState) = state else { return }
        filePath = markdownState.filePath
        currentTitle = markdownState.title
        scrollPosition = markdownState.scrollPosition
        if !markdownState.filePath.isEmpty {
            loadMarkdown(at: markdownState.filePath)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}
