import Cocoa

/// ContentViewProtocol implementation for text editor tabs.
/// Placeholder implementation for Phase 3.
final class EditorContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .editor

    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var filePath: String?
    private var currentTitle: String = "Untitled"

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
        setupTextView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTextView() {
        let sv = NSScrollView(frame: bounds)
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView(frame: sv.contentView.bounds)
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = AppSettings.shared.theme.background.nsColor
        tv.textColor = AppSettings.shared.theme.foreground.nsColor
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true

        sv.documentView = tv
        addSubview(sv)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        scrollView = sv
        textView = tv

        if let path = filePath {
            loadFile(at: path)
        }
    }

    private func loadFile(at path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        textView?.string = content
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(textView)
        onFocused?()
    }

    func deactivate() {
        // Text view stays alive
    }

    func cleanup() {
        textView = nil
        scrollView?.removeFromSuperview()
        scrollView = nil
    }

    func saveState() -> ContentState {
        .editor(
            EditorContentState(
                title: currentTitle,
                filePath: filePath,
                isDirty: textView?.undoManager?.canUndo ?? false
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .editor(let editorState) = state else { return }
        filePath = editorState.filePath
        currentTitle = editorState.title
        if let path = editorState.filePath {
            loadFile(at: path)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}
