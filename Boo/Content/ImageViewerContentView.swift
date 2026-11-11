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
        hud.onZoomLevel = { [weak self] level in self?.zoom(to: level) }
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
            hud.confirmCopy()
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

    /// Pinches over the HUD land here; zoom the image anyway.
    override func magnify(with event: NSEvent) {
        scrollView.magnify(with: event)
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

    /// Trackpad pinch, applied by hand: AppKit's own handling drops a gesture
    /// whose began phase went to another view (a pinch started over the HUD)
    /// or that arrives during scroll momentum.
    override func magnify(with event: NSEvent) {
        guard let documentView else { return }
        let point = documentView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * (1 + event.magnification), centeredAt: point)
        onMagnify?()
    }

    /// Two-finger double tap, same as double-click.
    override func smartMagnify(with event: NSEvent) {
        guard let documentView else { return }
        onDoubleClick?(documentView.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? ImageViewerContentView)?.focus()
        if event.clickCount == 2, let documentView {
            onDoubleClick?(documentView.convert(event.locationInWindow, from: nil))
            return
        }
        guard canPan else { return }
        dragStart = (event.locationInWindow, contentView.bounds.origin)
        NSCursor.closedHand.push()
    }

    /// Panning only makes sense when the image overflows the viewport.
    private var canPan: Bool {
        guard let documentView else { return false }
        let doc = documentView.frame.size
        let visible = contentView.bounds.size
        return doc.width > visible.width + 0.5 || doc.height > visible.height + 0.5
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

/// Dark pill toolbar over the image, like Quick Look: info on the left, zoom
/// controls in the middle, file actions on the right. Dark in every theme so
/// it stays legible over bright images.
private final class ImageViewerHUD: NSVisualEffectView {
    enum Action: Int { case zoomIn, zoomOut, fit, actualSize, openExternally, reveal, copy }

    var onAction: ((Action) -> Void)?
    var onZoomLevel: ((CGFloat) -> Void)?
    private let zoomButton = HUDButton()
    private let infoLabel = NSTextField(labelWithString: "")
    private var fitButton: HUDButton?
    private var copyButton: HUDButton?

    private static let presets: [CGFloat] = [0.25, 0.5, 1, 2, 4, 8]

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // The blur alone stays too light over bright images; tint it darker.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        zoomButton.title = "100%"
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomButton.toolTip = "Zoom level"
        zoomButton.target = self
        zoomButton.action = #selector(showZoomMenu(_:))
        zoomButton.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let fit = button("arrow.down.right.and.arrow.up.left", "Fit to window (0)", .fit)
        let actual = button(nil, "Actual size (1)", .actualSize)
        actual.title = "1:1"
        actual.font = .systemFont(ofSize: 11, weight: .semibold)
        actual.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let copy = button("doc.on.doc", "Copy image (⌘C)", .copy)
        fitButton = fit
        copyButton = copy

        let stack = NSStackView(views: [
            infoLabel,
            separator(),
            button("minus", "Zoom out (−)", .zoomOut),
            zoomButton,
            button("plus", "Zoom in (+)", .zoomIn),
            separator(),
            fit,
            actual,
            separator(),
            copy,
            button("folder", "Show in Finder", .reveal),
            button("arrow.up.forward.app", "Open in default app", .openExternally)
        ])
        stack.spacing = 2
        stack.setCustomSpacing(10, after: infoLabel)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setZoom(_ magnification: CGFloat, fit: Bool) {
        zoomButton.title = "\(Int((magnification * 100).rounded()))%"
        fitButton?.isOn = fit
    }

    func setInfo(_ text: String) {
        infoLabel.stringValue = text
    }

    /// Briefly swaps the copy icon for a checkmark.
    func confirmCopy() {
        guard let copyButton else { return }
        copyButton.image = Self.symbol("checkmark", "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copyButton] in
            copyButton?.image = Self.symbol("doc.on.doc", "Copy image (⌘C)")
        }
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    private func button(_ symbol: String?, _ tip: String, _ action: Action) -> HUDButton {
        let b = HUDButton()
        if let symbol { b.image = Self.symbol(symbol, tip) }
        b.toolTip = tip
        b.target = self
        b.action = #selector(buttonPressed(_:))
        b.tag = action.rawValue
        return b
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let action = Action(rawValue: sender.tag) { onAction?(action) }
    }

    @objc private func showZoomMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Fit to Window") { [weak self] in self?.onAction?(.fit) })
        menu.addItem(.separator())
        for level in Self.presets {
            menu.addItem(
                ClosureMenuItem(title: "\(Int(level * 100))%") { [weak self] in self?.onZoomLevel?(level) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// Borderless toolbar button with a hover and an "on" background.
private final class HUDButton: NSButton {
    var isOn = false { didSet { updateBackground() } }
    private var isHovered = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 6
        setButtonType(.momentaryChange)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        let width = widthAnchor.constraint(equalToConstant: 26)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([width, heightAnchor.constraint(equalToConstant: 24)])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var title: String {
        didSet { imagePosition = title.isEmpty ? .imageOnly : .noImage }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateBackground() {
        let alpha: CGFloat = isOn ? 0.2 : isHovered ? 0.1 : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}
