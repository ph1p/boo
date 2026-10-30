import Cocoa
import WebKit

// MARK: - EditorContentView

/// ContentViewProtocol implementation for text editor tabs using Monaco Editor via WKWebView.
final class EditorContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .editor

    /// Monaco gets unusably slow well before this; such files belong in a pager.
    private static let maxFileSize = 50 * 1024 * 1024

    private var webView: WKWebView?
    private var filePath: String?
    private var initialContent: String = ""
    /// The encoding the file was read in, and is written back in.
    private var encoding: String.Encoding = .utf8
    /// Why the file isn't editable (unreadable, binary, too large). While set the
    /// editor is read-only and saving is refused, so an empty or partial buffer
    /// can never overwrite the file.
    private var loadError: String?
    /// Reports other programs' writes; our own are noted so they don't echo back.
    private var watcher: WatchedFile?
    /// Set after a failed autosave so the next ones don't stack up alerts.
    private var autosaveFailed = false
    private var currentTitle: String
    private var isDirty = false
    private var isReady = false  // Set when JS signals 'ready'
    /// A line to jump to once the editor holds the file.
    private var pendingReveal: (line: Int, column: Int)?

    private enum SaveReason {
        /// ⌘S, Save As, or saving before close: runs the on-save edits and reports errors.
        case explicit
        /// Autosave when the editor loses focus: runs the on-save edits.
        case focusChange
        /// Autosave while typing: leaves the text alone so the cursor doesn't jump.
        case delay
    }

    // MARK: - Callbacks

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    /// Save on every (debounced) edit regardless of the autosave setting.
    var autosave = false
    /// Monaco options that win over the editor settings (e.g. a compact sidebar
    /// editor without line numbers). Set before the editor loads.
    var optionOverrides: [String: Any] = [:]

    var hasUnsavedChanges: Bool { isDirty }
    var fileDisplayName: String { fileName ?? "Untitled" }
    private var fileName: String? { filePath.map { ($0 as NSString).lastPathComponent } }

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
        startWatching()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    private func loadContentFromDisk(path: String) {
        debugLog("[Editor] Attempting to load from path: \(path)")
        initialContent = ""
        encoding = .utf8
        loadError = nil

        // A missing file is a new one; the first save creates it.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return }

        if let size = (attributes[.size] as? NSNumber)?.intValue, size > Self.maxFileSize {
            let megabytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            loadError = "This file is too large to edit here (\(megabytes))."
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            debugLog("[Editor] CRITICAL: Failed to load from disk: \(error.localizedDescription)")
            loadError = "Couldn't read this file: \(error.localizedDescription)"
            return
        }

        guard let (text, detected) = Self.decode(data) else {
            loadError = "This looks like a binary file, so it was opened read-only and empty."
            return
        }
        initialContent = text
        encoding = detected
        debugLog("[Editor] Loaded \(text.count) characters (\(Self.displayName(of: detected)))")
    }

    /// UTF-16 needs its byte order mark; other text never contains NUL bytes,
    /// which keeps binaries from being decoded as Mac Roman.
    private static func decode(_ data: Data) -> (String, String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map { ($0, .utf16) }
        }
        if data.prefix(8192).contains(0) { return nil }
        for candidate in [String.Encoding.utf8, .windowsCP1252, .macOSRoman] {
            if let text = String(data: data, encoding: candidate) { return (text, candidate) }
        }
        return nil
    }

    private static func displayName(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf16: return "UTF-16"
        case .windowsCP1252: return "Windows 1252"
        case .macOSRoman: return "Mac Roman"
        default: return "UTF-8"
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
        config.websiteDataStore = .nonPersistent()
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(self), name: "boo")
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

    /// A JS literal for `value` (an object, array or string).
    private func jsonString(from value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func sendInitialData() {
        var initData: [String: Any] = [
            "content": initialContent,
            "encoding": Self.displayName(of: encoding),
            "readOnly": loadError != nil,
            "themeData": buildMonacoTheme(),
            "options": buildEditorOptions()
        ]
        if let fileName { initData["fileName"] = fileName }
        if let loadError { initData["notice"] = loadError }

        guard let jsonStr = jsonString(from: initData) else { return }
        debugLog("[Editor] Sending initial data to JS (\(initialContent.count) chars)")
        webView?.evaluateJavaScript("initEditorFromJSON(\(jsonStr))") { [weak self] _, error in
            if let error = error {
                debugLog("[Editor] JS Init Error: \(error.localizedDescription)")
            } else {
                debugLog("[Editor] Initial data sent successfully")
                self?.applyPendingReveal()
            }
        }
    }

    /// Moves the cursor to `line`:`column` (1-based), now or once the editor is loaded.
    func reveal(line: Int, column: Int = 1) {
        pendingReveal = (max(1, line), max(1, column))
        if isReady { applyPendingReveal() }
    }

    private func applyPendingReveal() {
        guard let reveal = pendingReveal else { return }
        pendingReveal = nil
        webView?.evaluateJavaScript("revealPosition(\(reveal.line), \(reveal.column))")
    }

    /// Tells the editor the file name (for the language) and encoding after they change.
    private func sendFileInfo(includingName: Bool) {
        var info: [String: Any] = ["encoding": Self.displayName(of: encoding)]
        if includingName, let fileName { info["fileName"] = fileName }
        guard isReady, let json = jsonString(from: info) else { return }
        webView?.evaluateJavaScript("setFileInfo(\(json))")
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
        var opts: [String: Any] = [
            "fontFamily": settings.editorFontName,
            "fontSize": fontSize,
            "lineHeight": Int((fontSize * 1.5).rounded(.up)),
            "tabSize": settings.editorTabSize,
            "insertSpaces": settings.editorInsertSpaces,
            "detectIndentation": settings.editorDetectIndentation,
            "wordWrap": settings.editorWordWrap ? "on" : "off",
            "lineNumbers": settings.editorLineNumbers ? "on" : "off",
            "minimap": settings.editorMinimap,
            "renderWhitespace": settings.editorRenderWhitespace.rawValue,
            "bracketPairColors": settings.editorBracketPairColors,
            "stickyScroll": settings.editorStickyScroll,
            "fontLigatures": settings.editorFontLigatures,
            "cursorStyle": settings.editorCursorStyle.rawValue,
            "cursorBlinking": settings.editorCursorBlinking,
            "statusStrip": settings.editorShowStatusStrip
        ]
        if settings.editorRulerColumn > 0 {
            opts["rulers"] = [settings.editorRulerColumn]
        } else {
            opts["rulers"] = [Int]()
        }
        return opts.merging(optionOverrides) { _, override in override }
    }

    // MARK: - ContentViewProtocol

    func save(completion: ((Bool) -> Void)?) {
        saveFile(completion: completion)
    }

    func activate() {
        window?.makeFirstResponder(webView)
        webView?.evaluateJavaScript("focusEditor()")
        onFocused?()
        onTitleChanged?(currentTitle)
    }

    func deactivate() {
        autosaveOnFocusLoss()
    }

    func cleanup() {
        watcher?.stop()
        watcher = nil
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
        // The text comes back from disk, so the unsaved edits are gone.
        isDirty = false

        if let path = editorState.filePath, !path.isEmpty {
            loadContentFromDisk(path: path)
        } else {
            initialContent = ""
            loadError = nil
        }
        startWatching()

        updateTitle()

        if isReady {
            sendInitialData()
        }
    }

    // MARK: - Persistence

    /// Saves with the on-save edits; an untitled editor asks where.
    func saveFile(completion: ((Bool) -> Void)? = nil) {
        saveFile(reason: .explicit, completion: completion)
    }

    private func saveFile(reason: SaveReason, completion: ((Bool) -> Void)?) {
        if let loadError {
            if reason == .explicit { showSaveError("Nothing was saved, so the file stays as it is. \(loadError)") }
            completion?(false)
            return
        }
        guard let path = filePath else {
            if reason == .explicit {
                saveAs(completion: completion)
            } else {
                completion?(false)
            }
            return
        }
        contentForSave(applyingSaveActions: reason != .delay) { [weak self] payload in
            guard let self, let payload else {
                completion?(false)
                return
            }
            completion?(self.write(payload, to: path, reason: reason))
        }
    }

    /// Asks for a new location, writes there and keeps editing that file.
    func saveAs(completion: ((Bool) -> Void)? = nil) {
        if let loadError {
            showSaveError(loadError)
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileDisplayName
        if let filePath {
            panel.directoryURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        }

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            self.contentForSave(applyingSaveActions: true) { payload in
                guard let payload else {
                    completion?(false)
                    return
                }
                let previousPath = self.filePath
                self.filePath = url.path
                guard self.write(payload, to: url.path, reason: .explicit) else {
                    self.filePath = previousPath
                    completion?(false)
                    return
                }
                self.startWatching()
                self.sendFileInfo(includingName: true)
                self.updateTitle()
                completion?(true)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func autosaveOnFocusLoss() {
        if AppSettings.shared.editorAutosave == .onFocusChange { autosaveIfNeeded(.focusChange) }
    }

    private func autosaveIfNeeded(_ reason: SaveReason) {
        guard isDirty, filePath != nil, loadError == nil else { return }
        saveFile(reason: reason, completion: nil)
    }

    /// The text to write, after format on save, whitespace trimming and the
    /// final newline when `applyingSaveActions`.
    private func contentForSave(applyingSaveActions: Bool, completion: @escaping (SavePayload?) -> Void) {
        guard let webView else { return completion(nil) }
        let settings = AppSettings.shared
        let options: [String: Any] =
            applyingSaveActions
            ? [
                "format": settings.editorFormatOnSave,
                "trimTrailingWhitespace": settings.editorTrimTrailingWhitespace,
                "insertFinalNewline": settings.editorInsertFinalNewline
            ] : [:]
        webView.callAsyncJavaScript(
            "return await prepareSave(options)", arguments: ["options": options], in: nil, in: .page
        ) { result in
            switch result {
            case .success(let value):
                guard let dict = value as? [String: Any], let content = dict["content"] as? String,
                    let version = dict["version"] as? Int
                else { return completion(nil) }
                completion(SavePayload(content: content, version: version))
            case .failure(let error):
                debugLog("[Editor] Save failed reading content: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    private func write(_ payload: SavePayload, to path: String, reason: SaveReason) -> Bool {
        let content = payload.content
        var data = content.data(using: encoding)
        if data == nil {
            // The text gained characters the file's encoding can't store.
            let previous = Self.displayName(of: encoding)
            encoding = .utf8
            data = content.data(using: .utf8)
            sendFileInfo(includingName: false)
            BooAlert.showTransient("Saved as UTF-8: the text no longer fits \(previous).")
        }
        guard let data else { return false }

        // Writing through a symlink would replace the link with a plain file.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try data.write(to: url, options: .atomic)
            // The atomic replace is a new file; keep the original's mode (e.g. +x).
            if let permissions {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } catch {
            debugLog("[Editor] Save failed: \(error.localizedDescription)")
            if reason == .explicit || !autosaveFailed {
                showSaveError(error.localizedDescription)
            }
            if reason != .explicit { autosaveFailed = true }
            return false
        }
        autosaveFailed = false
        watcher?.noteOwnWrite()
        markClean(version: payload.version)
        return true
    }

    private func showSaveError(_ message: String) {
        BooAlert.showError(title: "Couldn't save \"\(fileDisplayName)\"", message: message, window: window)
    }

    /// Clears dirty state in Swift and JS unless edits landed during the write.
    private func markClean(version: Int) {
        webView?.evaluateJavaScript("markClean(\(version))") { [weak self] result, _ in
            guard let self, (result as? Bool) != false else { return }
            self.isDirty = false
            self.updateTitle()
        }
    }

    /// Re-reads the file from disk into the editor (after an external write),
    /// keeping the cursor and scroll position.
    func reload() {
        guard let path = filePath else { return }
        let wasReadOnly = loadError != nil
        loadContentFromDisk(path: path)
        isDirty = false
        updateTitle()
        guard isReady else { return }
        // Read-only state and the notice only change on a full re-init.
        if wasReadOnly || loadError != nil {
            sendInitialData()
            return
        }
        guard let json = jsonString(from: initialContent) else { return }
        webView?.evaluateJavaScript("setContent(\(json))")
        sendFileInfo(includingName: false)
    }

    // MARK: - External changes

    /// Watches the file's folder, which also catches editors that save by
    /// replacing the file (write to a temp file, then rename).
    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard let filePath else { return }
        // Watch the link's target: that's the folder its writes land in.
        let w = WatchedFile(path: (filePath as NSString).resolvingSymlinksInPath)
        w.start { [weak self] in self?.fileChangedOnDisk() }
        watcher = w
    }

    private func fileChangedOnDisk() {
        guard AppSettings.shared.editorReloadOnExternalChange, let path = filePath,
            FileManager.default.fileExists(atPath: path)
        else { return }  // Deleted: keep the buffer; saving recreates the file.

        guard isDirty else {
            debugLog("[Editor] \(fileDisplayName) changed on disk, reloading")
            reload()
            return
        }
        let banner: [String: Any] = [
            "id": "external",
            "message": "\(fileDisplayName) changed on disk.",
            "actions": [
                ["id": "reload", "label": "Reload"],
                ["id": "keep", "label": "Keep My Changes"]
            ]
        ]
        guard let json = jsonString(from: banner) else { return }
        webView?.evaluateJavaScript("showBanner(\(json))")
    }

    private func handleBannerAction(id: String, action: String) {
        guard id == "external" else { return }
        // "keep": WatchedFile already took this version as seen, so it isn't
        // reported again; saving overwrites it.
        if action == "reload" { reload() }
    }

    private func updateTitle() {
        let name = fileDisplayName
        let title = isDirty ? "\(name) ●" : name
        if title != currentTitle {
            currentTitle = title
            onTitleChanged?(title)
        }
    }
}

/// The text `prepareSave` returned and the model version it belongs to.
private struct SavePayload {
    let content: String
    let version: Int
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
            isDirty = dict["dirty"] as? Bool ?? true
            updateTitle()
        case "changed":
            if autosave || AppSettings.shared.editorAutosave == .afterDelay { autosaveIfNeeded(.delay) }
        case "focused":
            onFocused?()
        case "blurred":
            autosaveOnFocusLoss()
        case "bannerAction":
            if let id = dict["id"] as? String, let action = dict["action"] as? String {
                handleBannerAction(id: id, action: action)
            }
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

/// WKUserContentController retains its handlers, so registering the editor
/// itself would keep it (and its web view) alive until `cleanup()` runs.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
