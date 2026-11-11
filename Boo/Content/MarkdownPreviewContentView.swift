import Cocoa
import WebKit

/// ContentViewProtocol implementation for markdown preview tabs.
///
/// Links to other markdown files open in place (with a back stack), anchor
/// links scroll within the page, local images load through
/// `MarkdownAssetSchemeHandler`, and clicking an image opens a zoomable viewer.
final class MarkdownPreviewContentView: NSView, ContentViewProtocol, PageFindable {
    let contentType: ContentType = .markdownPreview

    private var webView: WKWebView?
    private var filePath: String?
    private var currentTitle: String = "Markdown"
    private var scrollPosition: CGFloat = 0
    /// Files visited before the current one, for the back button.
    private var backStack: [(path: String, scrollY: CGFloat)] = []

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onFindMatches: ((Int, Int) -> Void)?

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
        config.setURLSchemeHandler(MarkdownAssetSchemeHandler(), forURLScheme: MarkdownAssetSchemeHandler.scheme)
        config.userContentController.add(
            WeakScriptMessageHandler(self), name: MarkdownPreviewPage.messageHandler)
        let wv = WKWebView(frame: bounds, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        webView = wv

        let click = NSClickGestureRecognizer(target: self, action: #selector(webViewClicked))
        click.delaysPrimaryMouseButtonEvents = false
        wv.addGestureRecognizer(click)

        if let path = filePath {
            loadMarkdown(at: path)
        } else {
            showPlaceholder()
        }
    }

    @objc private func webViewClicked() {
        onFocused?()
    }

    // MARK: - Rendering

    private var colors: MarkdownPreviewPage.Colors {
        let theme = AppSettings.shared.theme
        return .init(
            background: theme.background.hexString,
            foreground: theme.foreground.hexString,
            muted: theme.chromeMuted.hexString)
    }

    private func loadMarkdown(at path: String, fragment: String? = nil) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            showPlaceholder()
            return
        }
        var options = MarkdownPreviewPage.Options()
        options.scrollY = Double(scrollPosition)
        options.fragment = fragment
        options.canGoBack = !backStack.isEmpty
        let html = MarkdownPreviewPage.document(
            body: MarkdownRenderer.renderHTML(from: content), colors: colors, options: options)
        webView?.loadHTMLString(html, baseURL: MarkdownAssetSchemeHandler.url(forPath: path))
    }

    private func showPlaceholder() {
        webView?.loadHTMLString(MarkdownPreviewPage.placeholder(colors: colors), baseURL: nil)
    }

    // MARK: - Navigation

    /// Open another markdown file in this tab, remembering the current one.
    private func navigate(toMarkdown path: String, fragment: String?) {
        if let current = filePath {
            backStack.append((current, scrollPosition))
        }
        show(path: path, scrollY: 0, fragment: fragment)
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        show(path: previous.path, scrollY: previous.scrollY, fragment: nil)
    }

    private func show(path: String, scrollY: CGFloat, fragment: String?) {
        filePath = path
        scrollPosition = scrollY
        currentTitle = (path as NSString).lastPathComponent
        onTitleChanged?(currentTitle)
        endFind()
        loadMarkdown(at: path, fragment: fragment)
    }

    /// Route a clicked link: anchors scroll, markdown opens in place, other
    /// local files open in a Boo tab, web links follow the app's link settings.
    private func openLink(_ url: URL) {
        let controller = window?.windowController as? MainWindowController
        guard let path = MarkdownAssetSchemeHandler.filePath(for: url) else {
            guard url.scheme?.lowercased() != "javascript" else { return }
            LinkOpener.open(.url(url), from: .init(cwd: nil, remote: nil, controller: controller))
            return
        }
        let fragment = url.fragment.flatMap { $0.isEmpty ? nil : $0 }
        if path == filePath {
            callPage("booScrollToFragment(fragment)", ["fragment": fragment ?? ""])
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            BooAlert.showTransient("No such file: \(path)")
            return
        }
        if isDirectory.boolValue {
            if let readme = Self.readme(in: path) {
                navigate(toMarkdown: readme, fragment: fragment)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            return
        }
        if ContentType.isMarkdown(path) {
            navigate(toMarkdown: path, fragment: fragment)
        } else if let controller {
            // Not LinkOpener: its editor target would open images as text.
            controller.handleOpenTab(.file(path: path))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private static func readme(in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.first {
            ($0 as NSString).deletingPathExtension.lowercased() == "readme" && ContentType.isMarkdown($0)
        }
        .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// Runs `body` as an async function in the page with `arguments` bound by name.
    private func callPage(
        _ body: String, _ arguments: [String: Any] = [:],
        completion: (@MainActor @Sendable (Result<Any, Error>) -> Void)? = nil
    ) {
        webView?.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: completion)
    }

    private func handleImageAction(_ type: String, src: String) {
        guard let url = URL(string: src) else { return }
        let localPath = MarkdownAssetSchemeHandler.filePath(for: url)
        switch type {
        case "openImage":
            NSWorkspace.shared.open(localPath.map { URL(fileURLWithPath: $0) } ?? url)
        case "revealImage":
            if let localPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: localPath)])
            }
        case "copyImagePath":
            PluginActions.copyToPasteboard(localPath ?? src)
        default:
            break
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "link":
            if let href = body["href"] as? String, let url = URL(string: href) { openLink(url) }
        case "back":
            goBack()
        case "scroll":
            if let y = body["y"] as? Double { scrollPosition = CGFloat(y) }
        default:
            if let src = body["src"] as? String { handleImageAction(type, src: src) }
        }
    }

    // MARK: - Find (PageFindable)

    func find(_ needle: String) {
        runFind("return booFind(needle)", arguments: ["needle": needle])
    }

    func findNext(_ forward: Bool) {
        runFind("return booFindStep(forward)", arguments: ["forward": forward])
    }

    func endFind() {
        callPage("window.booFindClear && booFindClear()")
    }

    private func runFind(_ script: String, arguments: [String: Any]) {
        callPage(script, arguments) { [weak self] result in
            let pair = (try? result.get()) as? [NSNumber]
            let selected = pair?.first?.intValue ?? -1
            let total = pair?.last?.intValue ?? 0
            self?.onFindMatches?(selected, total)
        }
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
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: MarkdownPreviewPage.messageHandler)
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
        backStack = []
        if !markdownState.filePath.isEmpty {
            loadMarkdown(at: markdownState.filePath)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - WebKit delegates

extension MarkdownPreviewContentView: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The page script routes link clicks itself; this catches anything that
    /// still tries to navigate (forms, meta refresh, middle clicks).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isInitialLoad =
            navigationAction.navigationType == .other
            && (url?.scheme == MarkdownAssetSchemeHandler.scheme || url?.absoluteString == "about:blank")
        if isInitialLoad || navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url { openLink(url) }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openLink(url) }
        return nil
    }
}
