import Cocoa
import SwiftUI
import WebKit

/// ContentViewProtocol implementation for browser tabs.
/// Uses WKWebView to display web content with a toolbar containing navigation buttons and URL bar.
final class BrowserContentView: NSView, ContentViewProtocol, NSTextFieldDelegate, NSMenuItemValidation {
    let contentType: ContentType = .browser

    private var urlBar: SelectAllTextField?
    private var backButton: NavHoverButton?
    private var forwardButton: NavHoverButton?
    private var reloadStopButton: NavHoverButton?
    private var webView: WKWebView?
    private weak var toolbarView: NSView?
    private weak var toolbarSeparator: NSView?
    private weak var progressView: BrowserProgressView?
    private weak var zoomButton: NSButton?
    private var urlBarToPill: NSLayoutConstraint?
    private var urlBarToZoom: NSLayoutConstraint?
    private var errorHost: NSHostingView<AnyView>?
    private var lastError: Error?
    private var currentURL: URL
    private var currentTitle: String = "New Tab"
    private var isLoading = false
    private var autocompletePanel: URLAutocompletePanel?
    private weak var urlBarPill: URLBarPillView?
    private var observations: [NSKeyValueObservation] = []
    private var completedDownloadDestinations: [ObjectIdentifier: URL] = [:]
    private weak var openExternalButton: NavHoverButton?
    private weak var serversButton: NavHoverButton?

    private var findNeedle = ""
    private var findTotal = 0
    private var findIndex = -1
    /// Bumped on every new search so late JS / find callbacks from an older
    /// needle can't overwrite the current match count.
    private var findGeneration = 0

    private let toolbarHeight: CGFloat = 44

    /// Safari's zoom ladder.
    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// Browser-specific: called when URL changes.
    var onURLChanged: ((URL) -> Void)?
    var onOpenURLInNewTab: ((URL) -> Void)?
    /// Find-in-page results: (selected index or -1, total or -1 for no search).
    var onFindMatches: ((Int, Int) -> Void)?

    // MARK: - Init

    init(url: URL) {
        self.currentURL = url
        super.init(frame: .zero)
        wantsLayer = true
        setupToolbar()
        setupWebView()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    deinit {
        for observation in observations { observation.invalidate() }
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyTheme()
    }

    /// Pane content uses the terminal background (like the editor and image
    /// viewer); chrome tokens only tint the controls on top of it.
    private func applyTheme() {
        let theme = AppSettings.shared.theme
        let background = theme.background.nsColor
        layer?.backgroundColor = background.cgColor
        toolbarView?.layer?.backgroundColor = background.cgColor
        toolbarSeparator?.layer?.backgroundColor = theme.separator.cgColor
        progressView?.color = theme.accentColor

        urlBar?.textColor = theme.chromeText
        urlBar?.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address",
            attributes: [.foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 12)])
        urlBarPill?.theme = theme
        for btn in [backButton, forwardButton, reloadStopButton, openExternalButton, serversButton] {
            btn?.hoverBackground = theme.hoverFill
        }
        for btn in [reloadStopButton, openExternalButton, serversButton] {
            btn?.contentTintColor = theme.textSecondary
        }
        updateNavButtons()
        updateZoomButton()

        // Pages that honor prefers-color-scheme follow the Boo theme, and the
        // overscroll / pre-paint area matches the pane instead of flashing white.
        if let wv = webView {
            wv.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            wv.underPageBackgroundColor = background
        }
        if let lastError { showError(lastError) }
    }

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        let theme = AppSettings.shared.theme
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
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
        toolbar.addSubview(separator)
        toolbarSeparator = separator

        // Load progress, drawn over the separator
        let progress = BrowserProgressView()
        progress.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(progress)
        progressView = progress

        NSLayoutConstraint.activate([
            separator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            progress.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])

        let back = makeNavButton(symbolName: "chevron.left", action: #selector(backAction), help: "Back")
        toolbar.addSubview(back)
        backButton = back

        let fwd = makeNavButton(symbolName: "chevron.right", action: #selector(forwardAction), help: "Forward")
        toolbar.addSubview(fwd)
        forwardButton = fwd

        let reload = makeNavButton(
            symbolName: "arrow.clockwise", action: #selector(reloadStopAction), help: "Reload Page")
        toolbar.addSubview(reload)
        reloadStopButton = reload

        // URL field — pill-style
        let bar = SelectAllTextField()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.font = .systemFont(ofSize: 12)
        bar.isBordered = false
        bar.drawsBackground = false
        bar.focusRingType = .none
        bar.lineBreakMode = .byTruncatingTail
        bar.cell?.isScrollable = true
        bar.delegate = self
        bar.target = self
        bar.action = #selector(urlBarAction(_:))

        let openExt = makeNavButton(
            symbolName: "arrow.up.right.square", action: #selector(openInExternalBrowserAction),
            help: "Open in Default Browser")
        toolbar.addSubview(openExt)
        openExternalButton = openExt

        let servers = makeNavButton(
            symbolName: "server.rack", action: #selector(showServersMenu(_:)), help: "Servers Running in Panes")
        toolbar.addSubview(servers)
        serversButton = servers

        // Pill container drawn behind the field
        let pill = URLBarPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.theme = theme
        toolbar.addSubview(pill)
        toolbar.addSubview(bar)
        urlBarPill = pill
        urlBar = bar

        // Page zoom badge inside the pill; hidden at 100%, click resets.
        let zoom = NSButton(title: "", target: self, action: #selector(resetFontSizeAction(_:)))
        zoom.translatesAutoresizingMaskIntoConstraints = false
        zoom.isBordered = false
        zoom.toolTip = "Reset Zoom"
        zoom.setContentCompressionResistancePriority(.required, for: .horizontal)
        zoom.setContentHuggingPriority(.required, for: .horizontal)
        toolbar.addSubview(zoom)
        zoomButton = zoom

        bar.onFocusGained = { [weak pill] in pill?.isFocused = true }
        bar.onFocusLost = { [weak pill] in pill?.isFocused = false }

        urlBarToPill = bar.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10)
        urlBarToZoom = bar.trailingAnchor.constraint(equalTo: zoom.leadingAnchor, constant: -6)

        // Layout: [8] [back] [2] [fwd] [2] [reload] [8] [pill: urlbar zoom] [4] [servers] [2] [openExt] [8]
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            fwd.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            fwd.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            reload.leadingAnchor.constraint(equalTo: fwd.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pill.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: servers.leadingAnchor, constant: -4),
            pill.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 26),

            bar.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            bar.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            zoom.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            zoom.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            servers.trailingAnchor.constraint(equalTo: openExt.leadingAnchor, constant: -2),
            servers.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            openExt.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            openExt.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        bar.stringValue = Self.displayString(for: currentURL)
    }

    private func makeNavButton(symbolName: String, action: Selector, help: String) -> NavHoverButton {
        let btn = NavHoverButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: help)?
            .withSymbolConfiguration(cfg)
        btn.toolTip = help
        btn.target = self
        btn.action = action
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 26),
            btn.heightAnchor.constraint(equalToConstant: 26)
        ])
        return btn
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore =
            AppSettings.shared.browserPersistentWebsiteDataEnabled ? .default() : .nonPersistent()
        let wv = WKWebView(frame: bounds, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        // Hidden until the first commit: an unpainted WKWebView is white, which
        // flashes on dark themes. The view's own background shows meanwhile.
        wv.isHidden = true
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor, constant: toolbarHeight),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView = wv

        // SPA route changes, document.title updates and history pushes never
        // fire navigation delegate callbacks, so mirror them through KVO.
        // Progress ticks many times per load, so it only moves the bar.
        func watch<Value>(
            _ keyPath: KeyPath<WKWebView, Value>,
            _ update: @escaping @MainActor (BrowserContentView) -> Void = { $0.syncWebViewState() }
        ) -> NSKeyValueObservation {
            wv.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    if let self { update(self) }
                }
            }
        }
        observations = [
            watch(\.url), watch(\.title), watch(\.isLoading), watch(\.canGoBack), watch(\.canGoForward),
            watch(\.estimatedProgress) { $0.updateProgress() }
        ]

        let click = NSClickGestureRecognizer(target: self, action: #selector(webViewClicked))
        click.delaysPrimaryMouseButtonEvents = false
        wv.addGestureRecognizer(click)

        if !Self.isBlank(currentURL) {
            load(currentURL)
        }
    }

    @objc private func webViewClicked() {
        onFocused?()
    }

    /// Mirror the web view's observable state into the toolbar and callbacks.
    private func syncWebViewState() {
        guard let wv = webView else { return }
        if let url = wv.url, url != currentURL {
            syncVisibleURL(url)
        }
        if let title = wv.title, !title.isEmpty, title != currentTitle {
            currentTitle = title
            onTitleChanged?(title)
        }
        if wv.isLoading != isLoading {
            isLoading = wv.isLoading
            updateLoadingState()
        }
        updateProgress()
        updateNavButtons()
    }

    private func updateProgress() {
        guard let wv = webView else { return }
        progressView?.progress = wv.isLoading ? wv.estimatedProgress : nil
    }

    // MARK: - Toolbar Actions

    @objc private func backAction() { goBack() }
    @objc private func forwardAction() { goForward() }

    @objc private func openInExternalBrowserAction() {
        guard currentURL.scheme != "about" else { return NSSound.beep() }
        NSWorkspace.shared.open(currentURL)
    }

    /// Lists the dev servers listening in any pane; picking one opens it here.
    @objc private func showServersMenu(_ sender: NSView) {
        PaneServerMonitor.shared.refresh { [weak self, weak sender] servers in
            guard let self, let sender else { return }
            let menu = NSMenu()
            if servers.isEmpty {
                let empty = NSMenuItem(title: "No Servers Running in Panes", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                menu.addItem(NSMenuItem.sectionHeader(title: "Servers Running in Panes"))
                for server in servers {
                    let item = NSMenuItem(
                        title: server.hostLabel, action: #selector(self.openServerMenuItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = server.url
                    item.subtitle = server.detail
                    item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
                    let isCurrent =
                        self.currentURL.port == Int(server.port)
                        && TerminalBridge.isLocalHost(self.currentURL.host ?? "")
                    item.state = isCurrent ? .on : .off
                    menu.addItem(item)
                }
            }
            let below = sender.isFlipped ? sender.bounds.maxY + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
        }
    }

    @objc private func openServerMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(to: url)
        window?.makeFirstResponder(webView)
    }

    @objc private func reloadStopAction() {
        if isLoading {
            stopLoading()
        } else {
            reload()
        }
    }

    @objc private func urlBarAction(_ sender: NSTextField) {
        autocompletePanel?.close()
        let knownPorts = Set(PaneServerMonitor.shared.servers.map(\.port))
        guard let url = Self.resolveInput(sender.stringValue, knownPorts: knownPorts) else { return }
        navigate(to: url)
        window?.makeFirstResponder(webView)
    }

    /// Turn address-bar input into a URL: explicit schemes and file paths load
    /// as-is, local hosts get http, anything that looks like a domain gets
    /// https, and everything else becomes a web search.
    ///
    /// Port shorthand: ":3000" always means localhost:3000; a bare "3000" does
    /// too when it is in `knownPorts` (a server running in a pane), and is a
    /// search otherwise.
    static func resolveInput(_ raw: String, knownPorts: Set<UInt16> = []) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let portDigits = input.hasPrefix(":") ? input.dropFirst() : Substring(input)
        if let port = UInt16(portDigits), port > 0, input.hasPrefix(":") || knownPorts.contains(port) {
            return URL(string: "http://localhost:\(port)")
        }

        if input.hasPrefix("/") || input == "~" || input.hasPrefix("~/") {
            return URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }

        if !input.contains(where: \.isWhitespace) {
            let lower = input.lowercased()
            if lower.contains("://") || ["about:", "data:", "mailto:", "file:"].contains(where: lower.hasPrefix),
                let url = URL(string: input), url.scheme != nil
            {
                return url
            }

            // `URL(string: "localhost:3000")` parses "localhost" as the scheme,
            // so inspect the host part by hand.
            let hostAndPort = lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            let host = hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isIPv4(host) {
                return URL(string: "http://\(input)")
            }
            if let tld = host.split(separator: ".").last, host.contains("."), tld.count >= 2,
                tld.allSatisfy(\.isLetter)
            {
                return URL(string: "https://\(input)")
            }
        }

        return searchURL(for: input)
    }

    static func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func isBlank(_ url: URL) -> Bool {
        url.absoluteString == "about:blank"
    }

    private static func displayString(for url: URL) -> String {
        isBlank(url) ? "" : url.absoluteString
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

        // Rescan once per edit (not per keystroke) and redraw if the servers
        // changed while the user is still in this field.
        let shown = PaneServerMonitor.shared.servers
        PaneServerMonitor.shared.refresh { [weak self] found in
            guard let self, found != shown, let urlBar = self.urlBar, urlBar.isFieldActive else { return }
            self.showAutocomplete(query: urlBar.stringValue.trimmingCharacters(in: .whitespaces))
        }
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
        // Escape with no suggestions open: abandon the edit, like Safari.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            urlBar?.stringValue = Self.displayString(for: currentURL)
            if webView?.isHidden == false {
                window?.makeFirstResponder(webView)
            } else {
                urlBar?.currentEditor()?.selectAll(nil)
            }
            return true
        }
        return false
    }

    private func showAutocomplete(query: String) {
        guard let anchor = urlBarPill else { return }
        ensureAutocompletePanel()

        let entries = BrowserHistory.shared.entries
        let filtered: [BrowserHistoryEntry]
        if query.isEmpty {
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

        let servers = Self.serverItems(PaneServerMonitor.shared.servers, matching: query)
        let serverURLs = Set(servers.map(\.url))
        let history = deduped.lazy.filter { !serverURLs.contains($0.url) }.prefix(8)
            .map { URLAutocompletePanel.Item(title: $0.title, url: $0.url) }
        let matches = servers + history

        if matches.isEmpty {
            autocompletePanel?.close()
        } else {
            autocompletePanel?.show(below: anchor, items: matches)
        }
    }

    /// Suggestions for servers running in panes. All of them on an empty
    /// query; otherwise those whose address, port, process or pane matches.
    static func serverItems(_ servers: [PaneServer], matching query: String) -> [URLAutocompletePanel.Item] {
        let needle = query.hasPrefix(":") ? String(query.dropFirst()) : query
        return
            servers
            .filter { server in
                let fields = [server.hostLabel, server.url.absoluteString, server.processName, server.location]
                return needle.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            .map {
                URLAutocompletePanel.Item(title: $0.hostLabel, url: $0.url, subtitle: $0.detail, symbol: "server.rack")
            }
    }

    private func ensureAutocompletePanel() {
        guard autocompletePanel == nil else { return }
        autocompletePanel = URLAutocompletePanel()
        autocompletePanel?.onSelect = { [weak self] url in
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
        backButton?.contentTintColor = canBack ? theme.chromeText : theme.textSecondary
        forwardButton?.contentTintColor = canFwd ? theme.chromeText : theme.textSecondary
    }

    private func updateLoadingState() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let symbolName = isLoading ? "xmark" : "arrow.clockwise"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        {
            reloadStopButton?.image = img
        }
        reloadStopButton?.toolTip = isLoading ? "Stop Loading" : "Reload Page"
    }

    // MARK: - Error Page

    private func showError(_ error: Error) {
        lastError = error
        let failedURL = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? currentURL
        let page = BrowserErrorView(url: failedURL, error: error) { [weak self] in
            self?.retryAfterError(failedURL)
        }
        .environment(\.tokens, .current)
        if let errorHost {
            errorHost.rootView = AnyView(page)
        } else {
            let host = NSHostingView(rootView: AnyView(page))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor, constant: toolbarHeight),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            errorHost = host
        }
        webView?.isHidden = true
    }

    private func hideError() {
        lastError = nil
        errorHost?.removeFromSuperview()
        errorHost = nil
    }

    private func retryAfterError(_ url: URL) {
        hideError()
        load(url)
    }

    // MARK: - Page Zoom

    static func nextZoom(from current: CGFloat, zoomIn: Bool) -> CGFloat {
        if zoomIn {
            return zoomSteps.first { $0 > current + 0.001 } ?? zoomSteps[zoomSteps.count - 1]
        }
        return zoomSteps.last { $0 < current - 0.001 } ?? zoomSteps[0]
    }

    /// Same selectors as the Terminal menu's font-size items: the browser sits
    /// ahead of the window controller in the responder chain, so ⌘+ / ⌘- / ⌘0
    /// zoom the page while it has focus.
    @objc func increaseFontSizeAction(_ sender: Any?) { setPageZoom(Self.nextZoom(from: pageZoom, zoomIn: true)) }
    @objc func decreaseFontSizeAction(_ sender: Any?) { setPageZoom(Self.nextZoom(from: pageZoom, zoomIn: false)) }
    @objc func resetFontSizeAction(_ sender: Any?) { setPageZoom(1) }

    var pageZoom: CGFloat { webView?.pageZoom ?? 1 }

    private func setPageZoom(_ zoom: CGFloat) {
        webView?.pageZoom = zoom
        updateZoomButton()
    }

    private func updateZoomButton() {
        guard let zoomButton else { return }
        let zoom = pageZoom
        let isDefault = abs(zoom - 1) < 0.001
        zoomButton.isHidden = isDefault
        urlBarToZoom?.isActive = false
        urlBarToPill?.isActive = false
        (isDefault ? urlBarToPill : urlBarToZoom)?.isActive = true
        zoomButton.attributedTitle = NSAttributedString(
            string: "\(Int((zoom * 100).rounded()))%",
            attributes: [
                .foregroundColor: AppSettings.shared.theme.textSecondary,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            ])
    }

    // MARK: - Menu Actions

    /// Focus the address bar (⌘L).
    @objc func browserOpenLocationAction(_ sender: Any?) {
        guard let urlBar else { return }
        window?.makeFirstResponder(urlBar)
        urlBar.currentEditor()?.selectAll(nil)
    }

    @objc func browserReloadAction(_ sender: Any?) { reload() }
    @objc func browserGoBackAction(_ sender: Any?) { goBack() }
    @objc func browserGoForwardAction(_ sender: Any?) { goForward() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserGoBackAction(_:)): return canGoBack
        case #selector(browserGoForwardAction(_:)): return canGoForward
        case #selector(increaseFontSizeAction(_:)): return pageZoom < Self.zoomSteps[Self.zoomSteps.count - 1]
        case #selector(decreaseFontSizeAction(_:)): return pageZoom > Self.zoomSteps[0]
        default: return true
        }
    }

    // MARK: - Find in Page

    private static let countMatchesScript = """
        const text = document.body ? document.body.innerText.toLowerCase() : "";
        const n = needle.toLowerCase();
        let count = 0;
        let i = text.indexOf(n);
        while (i !== -1) { count++; i = text.indexOf(n, i + n.length); }
        return count;
        """

    /// Start a new search. WKWebView's find API reports only found / not
    /// found, so the total comes from counting matches in the page text.
    func find(_ needle: String) {
        resetFind(needle: needle)
        let generation = findGeneration
        guard webView != nil, !needle.isEmpty else {
            clearPageSelection()
            onFindMatches?(-1, -1)
            return
        }
        Task { @MainActor [weak self] in
            // Called per keystroke and counting re-reads the whole page text,
            // so wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, generation == self.findGeneration else { return }
            self.countAndStepFind(needle, generation: generation)
        }
    }

    private func countAndStepFind(_ needle: String, generation: Int) {
        webView?.callAsyncJavaScript(
            Self.countMatchesScript, arguments: ["needle": needle], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self, generation == self.findGeneration else { return }
            let total = ((try? result.get()) as? NSNumber)?.intValue ?? 0
            self.findTotal = total
            guard total > 0 else {
                self.clearPageSelection()
                self.onFindMatches?(-1, 0)
                return
            }
            // Start from the top of the page, not after the previous match.
            self.clearPageSelection { [weak self] in
                self?.stepFind(forward: true, generation: generation)
            }
        }
    }

    func findNext(_ forward: Bool) {
        guard findTotal > 0 else { return }
        stepFind(forward: forward, generation: findGeneration)
    }

    func endFind() {
        resetFind(needle: "")
        clearPageSelection()
    }

    /// Invalidates in-flight find callbacks (via the generation) and clears counts.
    private func resetFind(needle: String) {
        findGeneration += 1
        findNeedle = needle
        findTotal = 0
        findIndex = -1
    }

    private func stepFind(forward: Bool, generation: Int) {
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        config.backwards = !forward
        webView?.find(findNeedle, configuration: config) { [weak self] result in
            guard let self, generation == self.findGeneration, result.matchFound, self.findTotal > 0 else { return }
            self.findIndex =
                forward
                ? (self.findIndex + 1) % self.findTotal
                : (self.findIndex - 1 + self.findTotal) % self.findTotal
            self.onFindMatches?(self.findIndex, self.findTotal)
        }
    }

    private func clearPageSelection(then completion: (@MainActor () -> Void)? = nil) {
        guard let webView else { return }
        webView.evaluateJavaScript("window.getSelection().removeAllRanges(); 0", in: nil, in: .defaultClient) { _ in
            completion?()
        }
    }

    // MARK: - ContentViewProtocol

    func activate() {
        // A blank tab has nothing to interact with yet; start in the address bar.
        if webView?.isHidden == false {
            window?.makeFirstResponder(webView)
        } else {
            browserOpenLocationAction(nil)
        }
        onFocused?()
    }

    func deactivate() {
        autocompletePanel?.close()
    }

    func cleanup() {
        autocompletePanel?.close()
        autocompletePanel = nil
        for observation in observations { observation.invalidate() }
        observations = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        hideError()
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
        currentTitle = browserState.title
        syncVisibleURL(browserState.url)
        if !Self.isBlank(browserState.url) {
            load(browserState.url)
        }
    }

    // MARK: - Browser-Specific API

    /// Navigate to a URL.
    func navigate(to url: URL) {
        syncVisibleURL(url)
        // The address bar may still own focus (Return was just pressed), which
        // makes syncVisibleURL leave its text alone.
        urlBar?.stringValue = Self.displayString(for: url)
        load(url)
    }

    private func load(_ url: URL) {
        guard let webView else { return }
        if url.isFileURL {
            let readAccess = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Go back in history.
    func goBack() { webView?.goBack() }

    /// Go forward in history.
    func goForward() { webView?.goForward() }

    /// Reload the current page; after a failed load there is no page to reload.
    func reload() {
        if lastError != nil || webView?.url == nil {
            hideError()
            if !Self.isBlank(currentURL) { load(currentURL) }
        } else {
            webView?.reload()
        }
    }

    /// Stop loading.
    func stopLoading() { webView?.stopLoading() }

    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    var url: URL { currentURL }
    var displayedURLString: String { urlBar?.stringValue ?? "" }

    func syncVisibleURL(_ url: URL) {
        currentURL = url
        // Don't clobber what the user is typing when a redirect or SPA route lands.
        if urlBar?.isFieldActive != true {
            urlBar?.stringValue = Self.displayString(for: url)
        }
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

    // WKWebView only handles Cmd+C/V/X/A/Z/Y when it is first responder.
    // performKeyEquivalent walks every view in the window, so only redirect
    // when focus is on this browser itself — never steal from another pane.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let wv = webView, event.type == .keyDown,
            event.modifierFlags.contains(.command),
            !wv.isHidden,
            window?.firstResponder === self
        else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers {
        case "c", "x", "v", "a", "z", "y":
            guard window?.makeFirstResponder(wv) == true else {
                return super.performKeyEquivalent(with: event)
            }
            return wv.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - NavHoverButton

/// Square toolbar button with a rounded-rect hover background.
/// Uses a layer-backed NSImageView for the icon so NSButton's cell never clips it.
final class NavHoverButton: NSView {
    /// Placeholder only — every creation path sets this from the theme
    /// (`makeNavButton`) and `applyTheme` re-sets it on theme change.
    var hoverBackground: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    var contentTintColor: NSColor? {
        didSet { imageView.contentTintColor = contentTintColor }
    }

    var image: NSImage? {
        didSet { imageView.image = image }
    }

    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    var target: AnyObject?
    var action: Selector?

    private let imageView = NSImageView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
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

    // Toolbar state (URL, title, loading, history) follows KVO in
    // syncWebViewState; these callbacks only handle their own side effects.

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
        webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !findNeedle.isEmpty {
            find(findNeedle)
        }
        // Record in browser history after title + URL are both known
        if let url = webView.url {
            BrowserHistory.shared.record(title: webView.title ?? "", url: url)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !BrowserErrorView.isSilent(error) else { return }
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's renderer crashed or was killed under memory pressure;
        // reloading brings it back instead of leaving a dead white view.
        webView.reload()
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

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let window else { return completionHandler() }
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard let window else { return completionHandler(false) }
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard let window else { return completionHandler(nil) }
        let alert = Self.pageAlert(message: prompt, frame: frame)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// Page dialogs name the site they came from so they can't pose as Boo.
    private static func pageAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
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
        guard let destination = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        else { return }
        // Bounce the Downloads stack in the Dock like Safari does.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: destination.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        _ = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }
}

// MARK: - URLBarPillView

/// Rounded-rect pill behind the URL text field.
/// Draws a focus ring around itself when the embedded field is first responder.
final class URLBarPillView: NSView {
    var theme: TerminalTheme? { didSet { needsDisplay = true } }
    /// Called by the text field's delegate to toggle focused appearance.
    var isFocused: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let radius = bounds.height / 2
        let inset = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        theme.subtleFill.setFill()
        path.fill()

        // Border: subtle when idle, focus ring when editing
        if isFocused {
            theme.focusRing.setStroke()
            path.lineWidth = 1.5
        } else {
            theme.separator.setStroke()
            path.lineWidth = 0.5
        }
        path.stroke()
    }
}

// MARK: - BrowserProgressView

/// Thin load-progress line along the bottom of the browser toolbar.
final class BrowserProgressView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    /// nil hides the bar.
    var progress: Double? {
        didSet {
            guard progress != oldValue else { return }
            isHidden = progress == nil
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let progress else { return }
        color.setFill()
        // Never fully empty: a just-started load still shows it is working.
        NSRect(x: 0, y: 0, width: bounds.width * max(0.08, min(progress, 1)), height: bounds.height).fill()
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
