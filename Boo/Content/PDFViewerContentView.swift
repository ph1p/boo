import Cocoa
import PDFKit

/// ContentViewProtocol implementation for PDF tabs, built on PDFKit.
///
/// Pages scroll continuously on the theme background. A HUD at the bottom has
/// page navigation, zoom and file actions; ⌘F searches the document through
/// the pane's find bar. The page and zoom are saved with the session.
final class PDFViewerContentView: NSView, ContentViewProtocol, PageFindable {
    let contentType: ContentType = .pdfViewer

    private let pdfView = FocusingPDFView()
    private let hud = PDFViewerHUD()
    private var filePath: String?
    private var currentTitle: String = "PDF"
    /// Page and zoom to apply once the view has a size (PDFKit drops them before).
    private var pendingPosition: (page: Int, zoom: CGFloat)?

    private static let minZoom: CGFloat = 0.1
    private static let maxZoom: CGFloat = 16

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
        setupViews()
        applyTheme()
        if let path = filePath { loadDocument(at: path) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange), name: .settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(updateHUD), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(updateHUD), name: .PDFViewScaleChanged, object: pdfView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        pdfView.autoScales = true
        pdfView.minScaleFactor = Self.minZoom
        pdfView.maxScaleFactor = Self.maxZoom
        pdfView.autoresizingMask = [.width, .height]
        pdfView.onMouseDown = { [weak self] in self?.onFocused?() }
        pdfView.frame = bounds
        addSubview(pdfView)

        hud.onAction = { [weak self] action in self?.perform(action) }
        hud.onZoomLevel = { [weak self] level in self?.zoom(to: level) }
        hud.onGoToPage = { [weak self] number in self?.goToPage(number - 1) }
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    private func loadDocument(at path: String) {
        endFind()
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            pdfView.document = nil
            hud.setPage(0, of: 0)
            hud.setUnavailable("Could not open \((path as NSString).lastPathComponent)")
            return
        }
        pdfView.document = document
        pdfView.autoScales = true
        updateHUD()
    }

    // MARK: - Pages

    private var pageCount: Int { pdfView.document?.pageCount ?? 0 }

    /// Zero-based index of the page at the top of the view.
    private var currentPageIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    private func goToPage(_ index: Int) {
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        let clamped = min(max(index, 0), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        pdfView.go(to: page)
        updateHUD()
    }

    // MARK: - Zoom

    private var isFitMode: Bool { pdfView.autoScales }

    private func fitToWidth() {
        pdfView.autoScales = true
        updateHUD()
    }

    private func zoom(to level: CGFloat) {
        // Keep the page in view: PDFKit zooms around the top-left corner otherwise.
        let page = pdfView.currentPage
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(level, Self.minZoom), Self.maxZoom)
        if let page, pdfView.currentPage != page { pdfView.go(to: page) }
        updateHUD()
    }

    private func perform(_ action: ViewerAction) {
        switch action {
        case .previousPage: goToPage(currentPageIndex - 1)
        case .nextPage: goToPage(currentPageIndex + 1)
        case .zoomIn: zoom(to: pdfView.scaleFactor * ViewerHUD.zoomStep)
        case .zoomOut: zoom(to: pdfView.scaleFactor / ViewerHUD.zoomStep)
        case .fit: fitToWidth()
        case .actualSize: zoom(to: 1)
        case .openExternally:
            if let filePath { NSWorkspace.shared.open(URL(fileURLWithPath: filePath)) }
        case .reveal:
            if let filePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)]) }
        case .copy: break
        }
    }

    @objc private func updateHUD() {
        hud.setPage(pageCount == 0 ? 0 : currentPageIndex + 1, of: pageCount)
        hud.setZoom(pdfView.scaleFactor, fit: isFitMode)
    }

    override func layout() {
        super.layout()
        guard let position = pendingPosition, bounds.width > 0, bounds.height > 0, pdfView.document != nil
        else { return }
        pendingPosition = nil
        // The fit scale is only right once the view has its size.
        if position.zoom > 0 { zoom(to: position.zoom) } else { fitToWidth() }
        goToPage(position.page)
    }

    // MARK: - Keyboard

    // The View menu's font-size items (⌘+ / ⌘- / ⌘0) reach the first
    // responder chain before the window controller, so they zoom the PDF.
    @objc func increaseFontSizeAction(_ sender: Any?) { perform(.zoomIn) }
    @objc func decreaseFontSizeAction(_ sender: Any?) { perform(.zoomOut) }
    @objc func resetFontSizeAction(_ sender: Any?) { perform(.fit) }

    /// Keys PDFView leaves unhandled bubble up here.
    override func keyDown(with event: NSEvent) {
        if let action = ViewerAction(keyEvent: event) { perform(action) } else { super.keyDown(with: event) }
    }

    // MARK: - Find (PageFindable)

    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private let findDebouncer = Debouncer(delay: 0.12)

    /// Searches after a short pause, so typing in a long document stays smooth.
    func find(_ needle: String) {
        findDebouncer.cancel()
        guard !needle.isEmpty, pdfView.document != nil else {
            clearMatches()
            onFindMatches?(-1, -1)
            return
        }
        findDebouncer.schedule { [weak self] in self?.runFind(needle) }
    }

    private func runFind(_ needle: String) {
        guard let document = pdfView.document else { return }
        let found = document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for selection in found { selection.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        matches = found
        pdfView.highlightedSelections = found.isEmpty ? nil : found
        guard !found.isEmpty else {
            matchIndex = -1
            pdfView.clearSelection()
            onFindMatches?(-1, 0)
            return
        }
        // Start at the first match on or after the page in view.
        let start = currentPageIndex
        matchIndex =
            found.firstIndex { selection in
                selection.pages.first.map { document.index(for: $0) >= start } ?? false
            } ?? 0
        showMatch()
    }

    func findNext(_ forward: Bool) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + (forward ? 1 : -1) + matches.count) % matches.count
        showMatch()
    }

    func endFind() {
        findDebouncer.cancel()
        clearMatches()
    }

    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.go(to: selection)
        onFindMatches?(matchIndex, matches.count)
        updateHUD()
    }

    private func clearMatches() {
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(pdfView)
        onFocused?()
    }

    func deactivate() {}

    func cleanup() {
        endFind()
        pdfView.document = nil
        pdfView.removeFromSuperview()
    }

    func saveState() -> ContentState {
        let position = pendingPosition
        return .pdfViewer(
            PDFViewerContentState(
                title: currentTitle,
                filePath: filePath ?? "",
                pageIndex: position?.page ?? currentPageIndex,
                // 0 means "fit to width".
                zoom: position?.zoom ?? (isFitMode ? 0 : pdfView.scaleFactor)
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .pdfViewer(let pdfState) = state else { return }
        currentTitle = pdfState.title
        if pdfState.filePath != filePath || pdfView.document == nil {
            filePath = pdfState.filePath
            if !pdfState.filePath.isEmpty { loadDocument(at: pdfState.filePath) }
        }
        pendingPosition = (max(pdfState.pageIndex, 0), max(pdfState.zoom, 0))
        needsLayout = true
    }

    // MARK: - Theme

    @objc private func settingsDidChange(_ note: Notification) {
        guard let raw = note.userInfo?["topic"] as? String,
            let topic = SettingsTopic(rawValue: raw),
            topic == .theme
        else { return }
        applyTheme()
    }

    private func applyTheme() {
        let background = AppSettings.shared.theme.background.nsColor
        layer?.backgroundColor = background.cgColor
        pdfView.backgroundColor = background
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    /// Hands focus on to the PDF, so arrow keys, text selection and ⌘C work.
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(self.pdfView)
        }
        return true
    }

    /// Pinches over the HUD land here; zoom the PDF anyway.
    override func magnify(with event: NSEvent) {
        pdfView.magnify(with: event)
    }
}

// MARK: - HUD

/// Page navigation on the left, zoom controls in the middle, file actions on the right.
private final class PDFViewerHUD: ViewerHUD, NSTextFieldDelegate {
    /// One-based page number typed into the page field.
    var onGoToPage: ((Int) -> Void)?

    private let pageField = NSTextField()
    private let pageCountLabel = NSTextField(labelWithString: "/ 0")
    private var previousButton: HUDButton?
    private var nextButton: HUDButton?
    private var controls: [NSControl] = []
    /// Last values from `setPage`, restored when the page field loses focus.
    private var page = (number: 0, count: 0)

    init() {
        super.init(fitTitle: "Fit to Width", presets: [0.5, 0.75, 1, 1.25, 1.5, 2, 4])
        pageField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        pageField.alignment = .center
        pageField.isBordered = false
        pageField.drawsBackground = false
        pageField.focusRingType = .none
        pageField.wantsLayer = true
        pageField.layer?.cornerRadius = 5
        pageField.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        pageField.toolTip = "Go to page"
        pageField.delegate = self
        pageField.widthAnchor.constraint(equalToConstant: 34).isActive = true

        pageCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageCountLabel.textColor = .secondaryLabelColor

        let previous = act("chevron.up", "Previous page", .previousPage)
        let next = act("chevron.down", "Next page", .nextPage)
        let zoomOut = act("minus", "Zoom out (−)", .zoomOut)
        let zoom = zoomLevel()
        let zoomIn = act("plus", "Zoom in (+)", .zoomIn)
        let fit = fit("arrow.left.and.right", "Fit to width (0)")
        let actual = actualSize()
        previousButton = previous
        nextButton = next
        controls = [previous, next, pageField, zoomOut, zoom, zoomIn, fit, actual]
        setItems(
            [
                previous, next, pageField, pageCountLabel, separator(),
                zoomOut, zoom, zoomIn, separator(),
                fit, actual, separator(),
                act("folder", "Show in Finder", .reveal),
                act("arrow.up.forward.app", "Open in default app", .openExternally)
            ])
        stack.setCustomSpacing(4, after: pageField)
        stack.setCustomSpacing(8, after: pageCountLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `number` is one-based; 0 when there is no document.
    func setPage(_ number: Int, of count: Int) {
        if count > 0, page.count == 0 { for control in controls { control.isEnabled = true } }
        page = (number, count)
        if pageField.currentEditor() == nil { pageField.stringValue = count == 0 ? "–" : "\(number)" }
        pageCountLabel.stringValue = "/ \(count)"
        previousButton?.isEnabled = number > 1
        nextButton?.isEnabled = number < count
    }

    /// Shows `message` instead of the page count and disables the controls.
    func setUnavailable(_ message: String) {
        page = (0, 0)
        pageCountLabel.stringValue = message
        for control in controls { control.isEnabled = false }
    }

    // Return jumps to the typed page; Escape or leaving the field restores it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let number = Int(pageField.stringValue.trimmingCharacters(in: .whitespaces)) {
                onGoToPage?(number)
            }
            window?.makeFirstResponder(superview)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(superview)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        pageField.stringValue = page.count == 0 ? "–" : "\(page.number)"
    }
}

/// Reports clicks, so a click on the page focuses the pane.
private final class FocusingPDFView: PDFView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}
