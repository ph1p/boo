import Cocoa

/// ContentViewProtocol implementation for image viewer tabs.
/// Placeholder implementation for Phase 3.
final class ImageViewerContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .imageViewer

    private var imageView: NSImageView?
    private var scrollView: NSScrollView?
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
        layer?.backgroundColor = NSColor.black.cgColor
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupImageView() {
        let sv = NSScrollView(frame: bounds)
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.backgroundColor = .black
        sv.translatesAutoresizingMaskIntoConstraints = false

        let iv = NSImageView(frame: sv.contentView.bounds)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter

        sv.documentView = iv
        addSubview(sv)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        scrollView = sv
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

    func deactivate() {
        // Image view stays alive
    }

    func cleanup() {
        imageView?.image = nil
        imageView = nil
        scrollView?.removeFromSuperview()
        scrollView = nil
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

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
}
