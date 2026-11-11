import Cocoa

/// ContentViewProtocol implementation for image viewer tabs.
///
/// The image sits in a magnifying scroll view: pinch or ⌘-scroll to zoom,
/// scroll or drag to pan, double-click to toggle fit / actual size. A HUD at
/// the bottom shows the zoom level and image info.
final class ImageViewerContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .imageViewer

    private let scrollView = ImageScrollView()
    private let imageView = NSImageView()
    private let hud = ImageViewerHUD()
    private var filePath: String?
    private var currentTitle: String = "Image"
    /// Fit mode re-fits on resize; any manual zoom leaves it.
    private var isFitMode = true

    private static let minZoom: CGFloat = 0.02
    private static let maxZoom: CGFloat = 40
    private static let zoomStep: CGFloat = 1.25

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
        setupViews()
        applyTheme()
        if let path = filePath { loadImage(at: path) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minZoom
        scrollView.maxMagnification = Self.maxZoom
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.onDoubleClick = { [weak self] point in self?.toggleFit(at: point) }
        scrollView.onMagnify = { [weak self] in self?.leaveFitMode() }

        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        scrollView.documentView = imageView
        addSubview(scrollView)

        hud.onAction = { [weak self] action in self?.perform(action) }
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    private func loadImage(at path: String) {
        guard let image = NSImage(contentsOfFile: path) else {
            imageView.image = nil
            hud.setInfo("Could not load \((path as NSString).lastPathComponent)")
            return
        }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        hud.setInfo(Self.info(for: image, path: path))
        fitToWindow()
    }

    private static func info(for image: NSImage, path: String) -> String {
        var parts: [String] = []
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
        } else {
            parts.append("\(Int(image.size.width)) × \(Int(image.size.height))")
        }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Zoom

    private var fitMagnification: CGFloat {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return 1 }
        let available = scrollView.bounds.insetBy(dx: 12, dy: 12).size
        return min(available.width / size.width, available.height / size.height, 1)
    }

    private func fitToWindow() {
        isFitMode = true
        scrollView.magnification = fitMagnification
        updateHUD()
    }

    private func zoom(to level: CGFloat, at point: NSPoint? = nil) {
        // setMagnification clamps to the scroll view's min/max.
        let visible = scrollView.contentView.documentVisibleRect
        let center = point ?? NSPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(level, centeredAt: center)
        leaveFitMode()
    }

    private func zoom(by factor: CGFloat) {
        zoom(to: scrollView.magnification * factor)
    }

    private func leaveFitMode() {
        isFitMode = false
        updateHUD()
    }

    /// Double-click: fit ⇄ actual size (2× when fit already is 1:1), around the clicked point.
    private func toggleFit(at point: NSPoint) {
        if !isFitMode {
            fitToWindow()
        } else {
            zoom(to: abs(fitMagnification - 1) > 0.01 ? 1 : 2, at: point)
        }
    }

    private func perform(_ action: ImageViewerHUD.Action) {
        switch action {
        case .zoomIn: zoom(by: Self.zoomStep)
        case .zoomOut: zoom(by: 1 / Self.zoomStep)
        case .fit: fitToWindow()
        case .actualSize: zoom(to: 1)
        case .openExternally:
            if let filePath { NSWorkspace.shared.open(URL(fileURLWithPath: filePath)) }
        case .reveal:
            if let filePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)]) }
        case .copy:
            guard let image = imageView.image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    private func updateHUD() {
        hud.setZoom(scrollView.magnification, fit: isFitMode)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if isFitMode, imageView.image != nil { fitToWindow() }
    }

    // MARK: - Keyboard

    // The View menu's font-size items (⌘+ / ⌘- / ⌘0) and Edit > Copy reach
    // the first responder before the window controller, so they zoom and
    // copy the image while it has focus.
    @objc func increaseFontSizeAction(_ sender: Any?) { perform(.zoomIn) }
    @objc func decreaseFontSizeAction(_ sender: Any?) { perform(.zoomOut) }
    @objc func resetFontSizeAction(_ sender: Any?) { perform(.fit) }
    @objc func copy(_ sender: Any?) { perform(.copy) }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": perform(.zoomIn)
        case "-": perform(.zoomOut)
        case "0": perform(.fit)
        case "1": perform(.actualSize)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - ContentViewProtocol

    func activate() {
        window?.makeFirstResponder(self)
        onFocused?()
    }

    func deactivate() {}

    func cleanup() {
        imageView.image = nil
        scrollView.removeFromSuperview()
    }

    func saveState() -> ContentState {
        .imageViewer(
            ImageViewerContentState(
                title: currentTitle,
                filePath: filePath ?? "",
                // 0 means "fit to window".
                zoom: isFitMode ? 0 : scrollView.magnification
            ))
    }

    func restoreState(_ state: ContentState) {
        guard case .imageViewer(let imageState) = state else { return }
        filePath = imageState.filePath
        currentTitle = imageState.title
        loadImage(at: imageState.filePath)
        // Older sessions stored 1.0 for every image; treat it as fit too.
        if imageState.zoom > 0, imageState.zoom != 1 {
            zoom(to: imageState.zoom)
        }
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
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        focus()
    }

    fileprivate func focus() {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        onFocused?()
    }
}

// MARK: - Scroll view

/// Magnifying scroll view: ⌘/⌥-scroll zooms around the cursor, drag pans,
/// double-click reports the clicked document point.
private final class ImageScrollView: NSScrollView {
    var onDoubleClick: ((NSPoint) -> Void)?
    var onMagnify: (() -> Void)?
    private var dragStart: (point: NSPoint, origin: NSPoint)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option),
            let documentView
        else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let factor = exp(delta * 0.01)
        let point = documentView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * factor, centeredAt: point)
        onMagnify?()
    }

    /// Trackpad pinch.
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnify?()
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? ImageViewerContentView)?.focus()
        if event.clickCount == 2, let documentView {
            onDoubleClick?(documentView.convert(event.locationInWindow, from: nil))
            return
        }
        dragStart = (event.locationInWindow, contentView.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let dx = (event.locationInWindow.x - start.point.x) / magnification
        let dy = (event.locationInWindow.y - start.point.y) / magnification
        var origin = start.origin
        origin.x -= dx
        origin.y += contentView.isFlipped ? dy : -dy
        contentView.scroll(
            to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}

/// Keeps an image smaller than the viewport centered instead of pinned to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - HUD

private final class ImageViewerHUD: NSVisualEffectView {
    enum Action: Int { case zoomIn, zoomOut, fit, actualSize, openExternally, reveal, copy }

    var onAction: ((Action) -> Void)?
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.toolTip = "Actual size (1)"
        zoomButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        zoomButton.target = self
        zoomButton.action = #selector(buttonPressed(_:))
        zoomButton.tag = Action.actualSize.rawValue

        let stack = NSStackView(views: [
            button("minus.magnifyingglass", "Zoom out (−)", .zoomOut),
            zoomButton,
            button("plus.magnifyingglass", "Zoom in (+)", .zoomIn),
            separator(),
            button("arrow.up.left.and.down.right.magnifyingglass", "Fit to window (0)", .fit),
            button("1.magnifyingglass", "Actual size (1)", .actualSize),
            separator(),
            infoLabel,
            separator(),
            button("doc.on.doc", "Copy image (⌘C)", .copy),
            button("folder", "Show in Finder", .reveal),
            button("arrow.up.forward.app", "Open in default app", .openExternally)
        ])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setZoom(_ magnification: CGFloat, fit: Bool) {
        zoomButton.title = "\(Int((magnification * 100).rounded()))%"
        zoomButton.contentTintColor = fit ? .secondaryLabelColor : .labelColor
    }

    func setInfo(_ text: String) {
        infoLabel.stringValue = text
    }

    private func button(_ symbol: String, _ tip: String, _ action: Action) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
        b.isBordered = false
        b.toolTip = tip
        b.tag = action.rawValue
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let action = Action(rawValue: sender.tag) { onAction?(action) }
    }
}
