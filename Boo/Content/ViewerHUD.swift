import Cocoa

/// Toolbar actions shared by the image and PDF viewers. Each viewer uses a subset.
enum ViewerAction: Int {
    case zoomIn, zoomOut, fit, actualSize, openExternally, reveal, copy, previousPage, nextPage

    /// Zoom keys without ⌘, ⌃ or ⌥: + (or =), −, 0 for fit, 1 for actual size.
    init?(keyEvent event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.charactersIgnoringModifiers {
        case "+", "=": self = .zoomIn
        case "-": self = .zoomOut
        case "0": self = .fit
        case "1": self = .actualSize
        default: return nil
        }
    }
}

/// Dark pill toolbar floating over viewer content (images, PDFs), like Quick
/// Look. Dark in every theme so it stays legible over bright pages. Subclasses
/// build their controls with `act(_:_:_:)`, `zoomButton(width:)` and
/// `separator()` and pass them to `setItems(_:)`.
class ViewerHUD: NSVisualEffectView {
    /// Multiplier for one zoom-in or zoom-out step.
    static let zoomStep: CGFloat = 1.25

    let stack = NSStackView()
    var onAction: ((ViewerAction) -> Void)?
    var onZoomLevel: ((CGFloat) -> Void)?

    private let fitTitle: String
    private let presets: [CGFloat]
    private var zoomLevelButton: HUDButton?
    private var fitButton: HUDButton?

    /// `fitTitle` and `presets` fill the menu of the zoom level button.
    init(fitTitle: String, presets: [CGFloat]) {
        self.fitTitle = fitTitle
        self.presets = presets
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

        // The blur alone stays too light over bright content; tint it darker.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays out `views` in one row. `leadingInset` is wider when the row starts with text.
    func setItems(_ views: [NSView], leadingInset: CGFloat = 6) {
        stack.setViews(views, in: .leading)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: leadingInset, bottom: 4, right: 6)
    }

    static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    /// An icon button that reports `action` through `onAction`.
    func act(_ symbol: String, _ tip: String, _ action: ViewerAction) -> HUDButton {
        button(symbol, tip, #selector(buttonPressed(_:)), tag: action.rawValue)
    }

    /// The "Fit" button. It shows as on while the viewer is in fit mode.
    func fit(_ symbol: String, _ tip: String) -> HUDButton {
        let b = act(symbol, tip, .fit)
        fitButton = b
        return b
    }

    /// The "1:1" text button.
    func actualSize() -> HUDButton {
        textButton(
            "1:1", "Actual size (1)", #selector(buttonPressed(_:)), width: 30, tag: ViewerAction.actualSize.rawValue)
    }

    /// The zoom percentage. A click opens the zoom presets.
    func zoomLevel() -> HUDButton {
        let b = textButton("100%", "Zoom level", #selector(zoomMenu(_:)), width: 50)
        zoomLevelButton = b
        return b
    }

    func setZoom(_ scale: CGFloat, fit: Bool) {
        zoomLevelButton?.title = "\(Int((scale * 100).rounded()))%"
        fitButton?.isOn = fit
    }

    func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    private func button(_ symbol: String?, _ tip: String, _ action: Selector, tag: Int = 0) -> HUDButton {
        let b = HUDButton()
        if let symbol { b.image = Self.symbol(symbol, tip) }
        b.toolTip = tip
        b.target = self
        b.action = action
        b.tag = tag
        return b
    }

    private func textButton(
        _ title: String, _ tip: String, _ action: Selector, width: CGFloat, tag: Int = 0
    )
        -> HUDButton
    {
        let b = button(nil, tip, action, tag: tag)
        b.title = title
        b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        if let action = ViewerAction(rawValue: sender.tag) { onAction?(action) }
    }

    /// Menu of zoom presets under the zoom level button, with "Fit" on top.
    @objc private func zoomMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: fitTitle) { [weak self] in self?.onAction?(.fit) })
        menu.addItem(.separator())
        for level in presets {
            menu.addItem(ClosureMenuItem(title: "\(Int(level * 100))%") { [weak self] in self?.onZoomLevel?(level) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// Borderless HUD button with a hover and an "on" background.
final class HUDButton: NSButton {
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

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateBackground() {
        let alpha: CGFloat = isOn ? 0.2 : isHovered && isEnabled ? 0.1 : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}
