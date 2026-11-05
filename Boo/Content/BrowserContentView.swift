import Cocoa
import SwiftUI
import WebKit

/// ContentViewProtocol implementation for browser tabs.
/// Uses WKWebView to display web content with a toolbar containing navigation buttons and URL bar.
final class BrowserContentView: NSView, ContentViewProtocol, NSTextFieldDelegate, NSMenuItemValidation {
    let contentType: ContentType = .browser

    var urlBar: SelectAllTextField?
    private var backButton: NavHoverButton?
    private var forwardButton: NavHoverButton?
    private var reloadStopButton: NavHoverButton?
    var webView: WKWebView?
    private weak var toolbarView: NSView?
    private weak var toolbarSeparator: NSView?
    private weak var progressView: BrowserProgressView?
    private weak var zoomButton: NSButton?
    private var urlBarToPill: NSLayoutConstraint?
    private var urlBarToZoom: NSLayoutConstraint?
    private var errorHost: NSHostingView<AnyView>?
    private var lastError: Error?
    var currentURL: URL
    private var currentTitle: String = "New Tab"
    private var isLoading = false
    var autocompletePanel: URLAutocompletePanel?
    weak var urlBarPill: URLBarPillView?
    private var observations: [NSKeyValueObservation] = []
    var completedDownloadDestinations: [ObjectIdentifier: URL] = [:]
    private weak var openExternalButton: NavHoverButton?
    private weak var serversButton: NavHoverButton?

    var findNeedle = ""
    var findTotal = 0
    var findIndex = -1
    /// Bumped on every new search so late JS / find callbacks from an older
    /// needle can't overwrite the current match count.
    var findGeneration = 0

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
        if AppSettings.shared.agentBrowserAccessEnabled {
            // `boo browser console` reads what the page logged.
            config.userContentController.addUserScript(
                WKUserScript(
                    source: AgentBrowser.consoleCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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

    func showError(_ error: Error) {
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

    func hideError() {
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

    func downloadsDirectoryURL() -> URL {
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
