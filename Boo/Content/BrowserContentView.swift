import Cocoa
import WebKit

/// ContentViewProtocol implementation for browser tabs.
/// Uses WKWebView to display web content with a toolbar containing navigation buttons and URL bar.
final class BrowserContentView: NSView, ContentViewProtocol, NSTextFieldDelegate {
    let contentType: ContentType = .browser

    private var urlBar: SelectAllTextField?
    private var backButton: NSButton?
    private var forwardButton: NSButton?
    private var reloadStopButton: NSButton?
    private var webView: WKWebView?
    private weak var toolbarView: NSView?
    private weak var toolbarSeparator: NSView?
    private var currentURL: URL
    private var currentTitle: String = "New Tab"
    private var isLoading = false
    private var autocompletePanel: URLAutocompletePanel?
    private weak var urlBarPill: URLBarPillView?
    private var urlObservation: NSKeyValueObservation?
    private var completedDownloadDestinations: [ObjectIdentifier: URL] = [:]

    private let toolbarHeight: CGFloat = 44

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// Browser-specific: called when URL changes.
    var onURLChanged: ((URL) -> Void)?
    var onOpenURLInNewTab: ((URL) -> Void)?

    // MARK: - Init

    init(url: URL) {
        self.currentURL = url
        super.init(frame: .zero)
        wantsLayer = true
        applyTheme()
        setupToolbar()
        setupWebView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    deinit {
        urlObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        applyTheme()
        applyToolbarTheme()
    }

    private func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.chromeBg.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        let theme = AppSettings.shared.theme
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = theme.background.nsColor.cgColor
        addSubview(toolbar)
        toolbarView = toolbar

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight)
        ])

        // Bottom separator
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.chromeBorder.cgColor
        toolbar.addSubview(separator)
        toolbarSeparator = separator
        NSLayoutConstraint.activate([
            separator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // Back button
        let back = makeNavButton(symbolName: "chevron.left", action: #selector(backAction), theme: theme)
        toolbar.addSubview(back)
        backButton = back

        // Forward button
        let fwd = makeNavButton(symbolName: "chevron.right", action: #selector(forwardAction), theme: theme)
        toolbar.addSubview(fwd)
        forwardButton = fwd

        // Reload/Stop button
        let reload = makeNavButton(symbolName: "arrow.clockwise", action: #selector(reloadStopAction), theme: theme)
        toolbar.addSubview(reload)
        reloadStopButton = reload

        // URL field — pill-style, matches active tab background
        let bar = SelectAllTextField()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.placeholderString = "Enter URL or search…"
        bar.font = .systemFont(ofSize: 12)
        bar.isBordered = false
        bar.drawsBackground = false
        bar.focusRingType = .none
        bar.textColor = theme.chromeText
        bar.delegate = self
        bar.target = self
        bar.action = #selector(urlBarAction(_:))

        // Pill container drawn behind the field
        let pill = URLBarPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.theme = theme
        toolbar.addSubview(pill)
        toolbar.addSubview(bar)
        urlBarPill = pill
        urlBar = bar

        bar.onFocusGained = { [weak pill] in pill?.isFocused = true }
        bar.onFocusLost = { [weak pill] in pill?.isFocused = false }

        // Layout: [8] [back] [4] [fwd] [4] [reload] [8] [pill/urlbar] [8]
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -1),

            fwd.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            fwd.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -1),

            reload.leadingAnchor.constraint(equalTo: fwd.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -1),

            pill.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            pill.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 26),

            bar.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])

        if currentURL.absoluteString != "about:blank" {
            bar.stringValue = currentURL.absoluteString
        }

        updateNavButtons()
    }

    private func makeNavButton(symbolName: String, action: Selector, theme: TerminalTheme) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        btn.image?.isTemplate = true
        btn.contentTintColor = theme.chromeMuted
        btn.target = self
        btn.action = action
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 26),
            btn.heightAnchor.constraint(equalToConstant: 26)
        ])
        return btn
    }

    private func applyToolbarTheme() {
        let theme = AppSettings.shared.theme
        toolbarView?.layer?.backgroundColor = theme.background.nsColor.cgColor
        toolbarSeparator?.layer?.backgroundColor = theme.chromeBorder.cgColor
        urlBar?.textColor = theme.chromeText
        urlBarPill?.theme = theme
        let activeColor = theme.chromeText
        let mutedColor = theme.chromeMuted
        backButton?.contentTintColor = (webView?.canGoBack ?? false) ? activeColor : mutedColor
        forwardButton?.contentTintColor = (webView?.canGoForward ?? false) ? activeColor : mutedColor
        reloadStopButton?.contentTintColor = mutedColor
        layer?.backgroundColor = theme.chromeBg.cgColor
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore =
            AppSettings.shared.browserPersistentWebsiteDataEnabled ? .default() : .nonPersistent()
        let wv = WKWebView(frame: bounds, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        urlObservation = wv.observe(\.url, options: [.initial, .new]) { [weak self] _, change in
            guard let url = change.newValue ?? nil else { return }
            Task { @MainActor [weak self] in
                self?.syncVisibleURL(url)
            }
        }
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor, constant: toolbarHeight),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView = wv

        if currentURL.absoluteString != "about:blank" {
            wv.load(URLRequest(url: currentURL))
        }
    }

    // MARK: - Toolbar Actions

    @objc private func backAction() { webView?.goBack() }
    @objc private func forwardAction() { webView?.goForward() }

    @objc private func reloadStopAction() {
        if isLoading {
            webView?.stopLoading()
        } else {
            webView?.reload()
        }
    }

    @objc private func urlBarAction(_ sender: NSTextField) {
        autocompletePanel?.close()
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

    // MARK: - NSTextFieldDelegate (autocomplete)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        showAutocomplete(query: query)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        showAutocomplete(query: query)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        autocompletePanel?.close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let event = NSApp.currentEvent
        if commandSelector == #selector(NSResponder.moveDown(_:))
            || commandSelector == #selector(NSResponder.moveUp(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:))
        {
            if let event, autocompletePanel?.handleKeyDown(with: event) == true {
                return true
            }
        }
        return false
    }

    private func showAutocomplete(query: String) {
        guard let anchor = urlBarPill else { return }
        ensureAutocompletePanel()

        let entries = BrowserHistory.shared.entries
        let filtered: [BrowserHistoryEntry]
        if query.count < 1 {
            filtered = Array(entries.prefix(8))
        } else {
            filtered = entries.filter {
                $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
        }

        // Deduplicate by URL, preserving order (most recent first)
        var seen = Set<URL>()
        let deduped = filtered.filter { seen.insert($0.url).inserted }

        let matches = deduped.prefix(8).map { URLAutocompletePanel.Item(title: $0.title, url: $0.url) }

        if matches.isEmpty {
            autocompletePanel?.close()
        } else {
            autocompletePanel?.show(below: anchor, items: matches)
        }
    }

    private func ensureAutocompletePanel() {
        guard autocompletePanel == nil else { return }
        autocompletePanel = URLAutocompletePanel()
        autocompletePanel?.onSelect = { [weak self] url in
            self?.urlBar?.stringValue = url.absoluteString
            self?.navigate(to: url)
            self?.window?.makeFirstResponder(self?.webView)
        }
    }

    private func updateNavButtons() {
        let theme = AppSettings.shared.theme
        let canBack = webView?.canGoBack ?? false
        let canFwd = webView?.canGoForward ?? false
        backButton?.isEnabled = canBack
        forwardButton?.isEnabled = canFwd
        backButton?.contentTintColor = canBack ? theme.chromeText : theme.chromeMuted
        forwardButton?.contentTintColor = canFwd ? theme.chromeText : theme.chromeMuted
    }

    private func updateLoadingState() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let symbolName = isLoading ? "xmark" : "arrow.clockwise"
        reloadStopButton?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        reloadStopButton?.image?.isTemplate = true
        reloadStopButton?.contentTintColor = AppSettings.shared.theme.chromeMuted
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
        urlObservation?.invalidate()
        urlObservation = nil
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
        syncVisibleURL(url)
        webView?.load(URLRequest(url: url))
    }

    /// Go back in history.
    func goBack() { webView?.goBack() }

    /// Go forward in history.
    func goForward() { webView?.goForward() }

    /// Reload the current page.
    func reload() { webView?.reload() }

    /// Stop loading.
    func stopLoading() { webView?.stopLoading() }

    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    var url: URL { currentURL }
    var displayedURLString: String { urlBar?.stringValue ?? "" }

    func syncVisibleURL(_ url: URL) {
        currentURL = url
        urlBar?.stringValue = url.absoluteString
        onURLChanged?(url)
    }

    func openURLInNewTab(_ url: URL) {
        if let onOpenURLInNewTab {
            onOpenURLInNewTab(url)
            return
        }
        if let paneView = enclosingPaneView() {
            _ = paneView.addNewTab(contentType: .browser, url: url)
        }
    }

    static func downloadDestinationURL(
        in directory: URL,
        suggestedFilename: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let fallbackName = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let baseURL = directory.appendingPathComponent(fallbackName)
        guard fileExists(baseURL) else { return baseURL }

        let directoryURL = baseURL.deletingLastPathComponent()
        let fileExtension = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let candidateName = fileExtension.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(fileExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !fileExists(candidateURL) {
                return candidateURL
            }
            suffix += 1
        }
    }

    private func enclosingPaneView() -> PaneView? {
        var current = superview
        while let view = current {
            if let paneView = view as? PaneView {
                return paneView
            }
            current = view.superview
        }
        return nil
    }

    private func downloadsDirectoryURL() -> URL {
        let fileManager = FileManager.default
        if let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            try? fileManager.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
            return downloadsURL
        }
        let fallbackURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    /// Forward standard edit commands (copy/cut/paste/select-all) to the web view
    /// so they work even when focus is on the container rather than the WKWebView itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let wv = webView, event.type == .keyDown,
            event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers {
        case "c":
            wv.perform(#selector(NSText.copy(_:)), with: nil)
            return true
        case "x":
            wv.perform(#selector(NSText.cut(_:)), with: nil)
            return true
        case "v":
            wv.perform(#selector(NSText.paste(_:)), with: nil)
            return true
        case "a":
            wv.perform(#selector(NSText.selectAll(_:)), with: nil)
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - WKNavigationDelegate

@MainActor
extension BrowserContentView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        updateLoadingState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateLoadingState()
        updateNavButtons()
        if let url = webView.url {
            syncVisibleURL(url)
        }
        if let title = webView.title, !title.isEmpty {
            currentTitle = title
            onTitleChanged?(title)
        }
        // Record in browser history after title + URL are both known
        if let url = webView.url {
            let title = webView.title ?? ""
            Task { @MainActor in
                BrowserHistory.shared.record(title: title, url: url)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateLoadingState()
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateLoadingState()
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavButtons()
        if let url = webView.url {
            syncVisibleURL(url)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

@MainActor
extension BrowserContentView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        openURLInNewTab(url)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        onCloseRequested?()
    }
}

// MARK: - WKDownloadDelegate

@MainActor
extension BrowserContentView: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destination = Self.downloadDestinationURL(
            in: downloadsDirectoryURL(),
            suggestedFilename: suggestedFilename
        )
        completedDownloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        _ = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        _ = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }
}

// MARK: - URLBarPillView

/// Rounded-rect pill behind the URL text field.
/// Background: sidebarBg (lighter than the active-tab toolbar).
/// Draws a focus ring around itself when the embedded field is first responder.
final class URLBarPillView: NSView {
    var theme: TerminalTheme? { didSet { needsDisplay = true } }
    /// Called by the text field's delegate to toggle focused appearance.
    var isFocused: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let radius = bounds.height / 2
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        // Fill: sidebar background (lighter than active-tab bg)
        theme.sidebarBg.setFill()
        path.fill()

        // Border: subtle when idle, accent-colored when focused
        if isFocused {
            theme.accentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
        } else {
            theme.chromeMuted.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 0.5
        }
        path.stroke()
    }
}

// MARK: - SelectAllTextField

/// NSTextField that:
/// - Calls `onFocusGained` immediately when it becomes first responder (click or Tab).
/// - Selects all text on the next run loop tick (field editor is installed by then).
/// - Watches `NSApplication.didUpdateNotification` to detect when focus leaves
///   (works on macOS 13+; `NSWindow.firstResponderDidChangeNotification` needs 14+).
/// - Calls `onFocusLost` and clears the observer when another view takes focus.
final class SelectAllTextField: NSTextField {
    var onFocusGained: (() -> Void)?
    var onFocusLost: (() -> Void)?

    private var focusObserver: NSObjectProtocol?
    var isFieldActive = false

    // True between becomeFirstResponder and the first mouseDown that follows.
    // When a click causes focus, becomeFirstResponder fires before mouseDown —
    // this flag lets mouseDown know whether it's the focus-gaining click or a
    // subsequent click on an already-focused field.
    var justBecameFirstResponder = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        guard result else { return false }

        justBecameFirstResponder = true
        isFieldActive = true
        onFocusGained?()

        // For Tab / programmatic focus there is no mouseDown, so select-all must
        // happen here. For click-focus, mouseDown will fire synchronously on the
        // same run-loop iteration and clear justBecameFirstResponder — the async
        // block then skips the selectAll to avoid fighting the cursor placement
        // that super.mouseDown already performed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.justBecameFirstResponder else { return }
            self.justBecameFirstResponder = false
            self.currentEditor()?.selectAll(nil)
        }

        if let obs = focusObserver {
            NotificationCenter.default.removeObserver(obs)
            focusObserver = nil
        }

        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let fr = window.firstResponder
                let fieldEditorOwnedByUs = (fr as? NSTextView)?.delegate as? NSTextField === self
                if fr !== self && !fieldEditorOwnedByUs {
                    self.isFieldActive = false
                    self.onFocusLost?()
                    if let obs = self.focusObserver {
                        NotificationCenter.default.removeObserver(obs)
                        self.focusObserver = nil
                    }
                }
            }
        }

        return true
    }

    override func mouseDown(with event: NSEvent) {
        if justBecameFirstResponder {
            // This click caused focus. Don't call super — it would run a blocking
            // mouse-tracking loop and place the cursor, overriding the selection.
            // becomeFirstResponder already installed the field editor; just select all.
            justBecameFirstResponder = false
            currentEditor()?.selectAll(nil)
        } else {
            // Field was already focused — normal cursor placement.
            super.mouseDown(with: event)
        }
    }
}
