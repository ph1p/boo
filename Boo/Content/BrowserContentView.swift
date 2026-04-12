import Cocoa
import WebKit

/// ContentViewProtocol implementation for browser tabs.
/// Uses WKWebView to display web content with an integrated URL bar.
final class BrowserContentView: NSView, ContentViewProtocol, NSTextFieldDelegate {
    let contentType: ContentType = .browser

    private var urlBar: NSTextField?
    private var webView: WKWebView?
    private var currentURL: URL
    private var currentTitle: String = "New Tab"

    private let urlBarHeight: CGFloat = 36

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// Browser-specific: called when URL changes.
    var onURLChanged: ((URL) -> Void)?

    // MARK: - Init

    init(url: URL) {
        self.currentURL = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupURLBar()
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupURLBar() {
        let bar = NSTextField()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.placeholderString = "Enter URL or search..."
        bar.font = .systemFont(ofSize: 13)
        bar.bezelStyle = .roundedBezel
        bar.isBordered = true
        bar.drawsBackground = true
        bar.backgroundColor = .textBackgroundColor
        bar.textColor = .labelColor
        bar.delegate = self
        bar.target = self
        bar.action = #selector(urlBarAction(_:))
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 24)
        ])
        urlBar = bar

        if currentURL.absoluteString != "about:blank" {
            bar.stringValue = currentURL.absoluteString
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: bounds, configuration: config)
        wv.navigationDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor, constant: urlBarHeight),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView = wv

        if currentURL.absoluteString != "about:blank" {
            wv.load(URLRequest(url: currentURL))
        }
    }

    @objc private func urlBarAction(_ sender: NSTextField) {
        let input = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        let url: URL
        if let parsed = URL(string: input), parsed.scheme != nil {
            url = parsed
        } else if input.contains(".") && !input.contains(" ") {
            url = URL(string: "https://\(input)") ?? ContentType.blankURL
        } else {
            let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
            url = URL(string: "https://www.google.com/search?q=\(query)") ?? ContentType.blankURL
        }

        navigate(to: url)
        window?.makeFirstResponder(webView)
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(webView)
        onFocused?()
    }

    func deactivate() {
        // WebView stays alive in background
    }

    func cleanup() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    func saveState() -> ContentState {
        .browser(
            BrowserContentState(
                title: currentTitle,
                url: currentURL,
                canGoBack: webView?.canGoBack ?? false,
                canGoForward: webView?.canGoForward ?? false
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .browser(let browserState) = state else { return }
        currentURL = browserState.url
        currentTitle = browserState.title
        if browserState.url.absoluteString != "about:blank" {
            webView?.load(URLRequest(url: browserState.url))
        }
    }

    // MARK: - Browser-Specific API

    /// Navigate to a URL.
    func navigate(to url: URL) {
        currentURL = url
        urlBar?.stringValue = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    /// Go back in history.
    func goBack() {
        webView?.goBack()
    }

    /// Go forward in history.
    func goForward() {
        webView?.goForward()
    }

    /// Reload the current page.
    func reload() {
        webView?.reload()
    }

    /// Stop loading.
    func stopLoading() {
        webView?.stopLoading()
    }

    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    var url: URL { currentURL }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - WKNavigationDelegate

extension BrowserContentView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            currentURL = url
            urlBar?.stringValue = url.absoluteString
            onURLChanged?(url)
        }
        if let title = webView.title, !title.isEmpty {
            currentTitle = title
            onTitleChanged?(title)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            currentURL = url
            urlBar?.stringValue = url.absoluteString
            onURLChanged?(url)
        }
    }
}
