import Cocoa
import WebKit

// MARK: - EditorContentView

/// ContentViewProtocol implementation for text editor tabs using Monaco Editor via WKWebView.
final class EditorContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .editor

    private var webView: WKWebView?
    private var filePath: String?
    private var initialContent: String = ""
    private var currentTitle: String
    private var isDirty = false
    private var isReady = false  // Set when JS signals 'ready'

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    var hasUnsavedChanges: Bool { isDirty }
    var fileDisplayName: String { filePath.map { ($0 as NSString).lastPathComponent } ?? "Untitled" }

    // MARK: - Init

    init(filePath: String?, content: String = "") {
        self.filePath = filePath

        if let path = filePath {
            self.currentTitle = (path as NSString).lastPathComponent
        } else {
            self.currentTitle = "Untitled"
        }

        super.init(frame: .zero)

        // Resolve content
        if !content.isEmpty {
            self.initialContent = content
            debugLog("[Editor] Using provided content (\(content.count) chars)")
        } else if let path = filePath {
            loadContentFromDisk(path: path)
        }

        setupWebView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    private func loadContentFromDisk(path: String) {
        debugLog("[Editor] Attempting to load from path: \(path)")
        let url = URL(fileURLWithPath: path)

        // Try reading with various encodings or as data first
        do {
            // First try to coordinate access if it's a sandbox path (optional improvement)
            let loaded = try String(contentsOf: url, encoding: .utf8)
            self.initialContent = loaded
            debugLog("[Editor] Successfully loaded \(loaded.count) characters from disk")
        } catch {
            debugLog("[Editor] UTF-8 load failed, trying MacOSRoman: \(error.localizedDescription)")
            do {
                let loaded = try String(contentsOf: url, encoding: .macOSRoman)
                self.initialContent = loaded
                debugLog("[Editor] Successfully loaded \(loaded.count) characters (MacOSRoman)")
            } catch {
                debugLog("[Editor] CRITICAL: Failed to load from disk: \(error.localizedDescription)")
                self.initialContent = ""
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func settingsDidChange() {
        applyEditorAppearance()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "boo")
        config.userContentController = contentController

        // Development settings
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Enable local file access for bundled Monaco assets and workers.
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let wv = WKWebView(frame: bounds, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")  // Transparency
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView = wv

        loadMonaco()
    }

    private func loadMonaco() {
        guard let bundleRoot = BooResourceBundle.bundle.resourceURL else {
            debugLog("[Editor] CRITICAL: MonacoBundle/index.html NOT FOUND in bundle")
            return
        }
        let bundleURL =
            bundleRoot
            .appendingPathComponent("MonacoBundle", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            debugLog("[Editor] CRITICAL: MonacoBundle/index.html NOT FOUND in bundle")
            return
        }

        debugLog("[Editor] Monaco bundle found at \(bundleURL.path)")
        webView?.loadFileURL(bundleURL, allowingReadAccessTo: bundleURL.deletingLastPathComponent())
    }

    private func jsonString(from object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private func sendInitialData() {
        let language = getMonacoLanguage()
        let monacoTheme = buildMonacoTheme()

        let initData: [String: Any] = [
            "content": initialContent,
            "language": language,
            "themeData": monacoTheme,
            "options": buildEditorOptions()
        ]

        guard let jsonStr = jsonString(from: initData) else { return }
        debugLog("[Editor] Sending initial data to JS (\(initialContent.count) chars)")
        webView?.evaluateJavaScript("initEditorFromJSON(\(jsonStr))") { _, error in
            if let error = error {
                debugLog("[Editor] JS Init Error: \(error.localizedDescription)")
            } else {
                debugLog("[Editor] Initial data sent successfully")
            }
        }
    }

    private func getMonacoLanguage() -> String {
        guard let path = filePath else { return "plaintext" }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs": return "javascript"
        case "ts": return "typescript"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        case "py": return "python"
        case "sh", "bash", "zsh": return "shell"
        case "yml", "yaml": return "yaml"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc", "hh": return "cpp"
        default: return "plaintext"
        }
    }

    private func applyEditorAppearance() {
        guard let themeStr = jsonString(from: buildMonacoTheme()),
            let optionsStr = jsonString(from: buildEditorOptions())
        else { return }
        webView?.evaluateJavaScript("setAppearance(\(themeStr), \(optionsStr))")
    }

    private func buildMonacoTheme() -> [String: Any] {
        let theme = AppSettings.shared.theme
        let isDark = theme.isDark

        return [
            "base": isDark ? "vs-dark" : "vs",
            "inherit": true,
            "rules": [
                ["token": "", "foreground": theme.foreground.hexString],
                ["token": "comment", "foreground": theme.ansiBlue.hexString, "fontStyle": "italic"],
                ["token": "keyword", "foreground": theme.ansiMagenta.hexString, "fontStyle": "bold"],
                ["token": "string", "foreground": theme.ansiGreen.hexString],
                ["token": "number", "foreground": theme.ansiYellow.hexString],
                ["token": "type", "foreground": theme.ansiCyan.hexString],
                ["token": "function", "foreground": theme.ansiBlue.hexString]
            ],
            "colors": [
                "editor.background": theme.background.hexString,
                "editor.foreground": theme.foreground.hexString,
                "editorCursor.foreground": theme.cursor.hexString,
                "editor.lineHighlightBackground": theme.background.highlight(0.05).hexString,
                "editor.selectionBackground": theme.selection.hexString,
                "editorIndentGuide.background": theme.chromeBorder.hexString
            ]
        ]
    }

    private func buildEditorOptions() -> [String: Any] {
        let settings = AppSettings.shared
        let fontSize = Double(settings.editorFontSize)
        return [
            "fontFamily": settings.editorFontName,
            "fontSize": fontSize,
            "lineHeight": Int((fontSize * 1.5).rounded(.up))
        ]
    }

    // MARK: - ContentViewProtocol

    func save(completion: ((Bool) -> Void)?) {
        saveFile(completion: completion)
    }

    func activate() {
        window?.makeFirstResponder(webView)
        webView?.evaluateJavaScript("focusEditor()")
        onFocused?()
    }

    func deactivate() {}

    func cleanup() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "boo")
        webView?.removeFromSuperview()
        webView = nil
    }

    func saveState() -> ContentState {
        .editor(
            EditorContentState(
                title: currentTitle,
                filePath: filePath,
                isDirty: isDirty
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .editor(let editorState) = state else { return }
        filePath = editorState.filePath
        isDirty = editorState.isDirty

        if let path = editorState.filePath, !path.isEmpty {
            loadContentFromDisk(path: path)
        } else {
            initialContent = ""
        }

        updateTitle()

        if currentTitle != editorState.title {
            currentTitle = editorState.title
            onTitleChanged?(editorState.title)
        }

        if isReady {
            sendInitialData()
        }
    }

    // MARK: - Persistence

    func saveFile(completion: ((Bool) -> Void)? = nil) {
        guard let path = filePath else {
            completion?(false)
            return
        }
        webView?.evaluateJavaScript("getContent()") { [weak self] result, error in
            guard let self else {
                completion?(false)
                return
            }
            if let error {
                debugLog("[Editor] Save failed reading content: \(error.localizedDescription)")
                completion?(false)
                return
            }
            guard let content = result as? String else {
                completion?(false)
                return
            }
            do {
                try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                self.isDirty = false
                self.updateTitle()
                completion?(true)
            } catch {
                debugLog("[Editor] Save failed: \(error.localizedDescription)")
                completion?(false)
            }
        }
    }

    private func updateTitle() {
        let name = filePath != nil ? (filePath! as NSString).lastPathComponent : "Untitled"
        let title = isDirty ? "\(name) ●" : name
        if title != currentTitle {
            currentTitle = title
            onTitleChanged?(title)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension EditorContentView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
            let type = dict["type"] as? String
        else { return }

        switch type {
        case "log":
            if let msg = dict["message"] as? String { debugLog("[Editor JS] \(msg)") }
        case "error":
            if let msg = dict["message"] as? String { debugLog("[Editor JS ERROR] \(msg)") }
        case "ready":
            debugLog("[Editor JS] Monaco is ready to receive data")
            isReady = true
            sendInitialData()
        case "dirty":
            isDirty = true
            updateTitle()
        case "focused":
            onFocused?()
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension EditorContentView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("[Editor] WebView main frame loaded")
        // We wait for the "ready" message from JS before sending data
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        debugLog("[Editor] WebView navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        debugLog("[Editor] WebView provisional navigation failed: \(error.localizedDescription)")
    }
}
