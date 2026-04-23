import Cocoa

/// ContentViewProtocol implementation for image viewer tabs.
final class ImageViewerContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .imageViewer

    private var imageView: NSImageView?
    private var filePath: String?
    private var currentTitle: String = "Image"
    private var zoom: CGFloat = 1.0

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
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupImageView() {
        let iv = NSImageView(frame: bounds)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)
        imageView = iv

        if let path = filePath {
            loadImage(at: path)
        }
    }

    private func loadImage(at path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        imageView?.image = image
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(self)
        onFocused?()
    }

    func deactivate() {}

    func cleanup() {
        imageView?.image = nil
        imageView?.removeFromSuperview()
        imageView = nil
    }

    func saveState() -> ContentState {
        .imageViewer(
            ImageViewerContentState(
                title: currentTitle,
                filePath: filePath ?? "",
                zoom: zoom
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .imageViewer(let imageState) = state else { return }
        filePath = imageState.filePath
        currentTitle = imageState.title
        zoom = imageState.zoom
        loadImage(at: imageState.filePath)
    }

    // MARK: - Theme

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    @objc private func settingsDidChange(_ note: Notification) {
        guard let raw = note.userInfo?["topic"] as? String,
            let topic = SettingsTopic(rawValue: raw),
            topic == .theme
        else { return }
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        onFocused?()
    }
}
