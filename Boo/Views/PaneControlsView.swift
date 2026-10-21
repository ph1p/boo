import Cocoa

/// What a pane-controls item asks the window to do.
enum PaneControlAction {
    case toggleRecording
    case addMarker
    case splitRight
    case splitDown
    case toggleZoom
    case closePane
}

/// One pane action as the notch's ⋯ menu lists it.
struct PaneControlEntry: Equatable {
    let action: PaneControlAction
    let title: String
    let symbol: String
}

/// Tab carved into a pane's bottom-right corner, over any tab type: a ⋯
/// button whose menu holds the pane actions. While the pane records it also
/// shows the elapsed time (click to stop), and while zoomed an unzoom button;
/// those stay when the pointer leaves, so neither state is ever invisible.
final class PaneControlsView: NSView {
    static let bodyHeight: CGFloat = 24
    /// Radius of the concave curves joining the pane's bottom and right edges.
    static let fillet: CGFloat = 6
    static let height: CGFloat = bodyHeight + fillet
    private static let cornerRadius: CGFloat = 7
    private static let itemHeight: CGFloat = 20
    /// Square buttons, so the glyph sits as far from the sides as from top and bottom.
    static let buttonWidth: CGFloat = itemHeight
    /// One gap on every side and between items: the space above and below an item.
    static let inset: CGFloat = (bodyHeight - itemHeight) / 2
    /// Concentric with the notch's rounded corner.
    static let itemCornerRadius: CGFloat = cornerRadius - inset
    /// Widest the notch gets over a tab that can't record: ⋯ plus unzoom.
    /// Content with controls in its bottom-right corner keeps this clear.
    static let nonRecordingMaxWidth: CGFloat = fillet + 2 * buttonWidth + 3 * inset

    var onAction: ((PaneControlAction) -> Void)?
    var onUnzoom: (() -> Void)?
    /// The notch's width changed on its own (the recording timer grew a digit).
    var onResize: (() -> Void)?
    /// Builds the ⋯ menu on demand, so it always reflects current state.
    var menuProvider: (() -> NSMenu?)?

    private let recordChip = RecordChip()
    private let unzoom = PaneControlButton(
        symbol: "arrow.down.right.and.arrow.up.left", help: "Show All Panes (\u{21E7}\u{2318}\u{23CE})")
    private let more = PaneControlButton(symbol: "ellipsis", help: "Pane Actions")

    /// Whether the ⋯ button shows, or only the recording / zoom state.
    private(set) var isExpanded = false
    private(set) var isZoomed = false

    /// Unflipped, so the shape and items measure up from the pane's bottom edge.
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        recordChip.onClick = { [weak self] in self?.onAction?(.toggleRecording) }
        recordChip.onWidthChange = { [weak self] in self?.onResize?() }
        unzoom.onClick = { [weak self] in self?.onUnzoom?() }
        more.onClick = { [weak self] in self?.showMoreMenu() }
        for view in [recordChip, unzoom, more] as [NSView] { addSubview(view) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane Controls")
        configure(expanded: false, recordingSince: nil, isZoomed: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        for button in [unzoom, more] { button.applyTheme() }
        recordChip.applyTheme()
        needsDisplay = true
    }

    /// Updates which items show and whether the recording timer runs.
    func configure(expanded: Bool, recordingSince: Date?, isZoomed: Bool) {
        isExpanded = expanded
        self.isZoomed = isZoomed
        recordChip.recordingSince = recordingSince
        recordChip.isHidden = recordingSince == nil
        unzoom.isHidden = !isZoomed
        more.isHidden = !expanded
        setFrameSize(fittingSize)
        needsLayout = true
    }

    /// True when there is nothing to show — collapsed, not recording, not zoomed.
    var isEmpty: Bool { !isExpanded && recordChip.recordingSince == nil && !isZoomed }

    private var visibleItems: [PaneControlItem] { [recordChip, unzoom, more].filter { !$0.isHidden } }

    override var fittingSize: NSSize {
        let items = visibleItems.reduce(CGFloat(0)) { $0 + itemWidth($1) }
        let gaps = CGFloat(visibleItems.count + 1) * Self.inset
        return NSSize(width: Self.fillet + items + gaps, height: Self.height)
    }

    private func itemWidth(_ item: PaneControlItem) -> CGFloat {
        item === recordChip ? recordChip.fittingSize.width : Self.buttonWidth
    }

    /// The tab itself, without the fillets: the only part that takes clicks.
    var bodyRect: NSRect {
        NSRect(x: Self.fillet, y: 0, width: max(0, bounds.width - Self.fillet), height: Self.bodyHeight)
    }

    override func layout() {
        super.layout()
        var x = Self.fillet + Self.inset
        for item in visibleItems {
            let w = itemWidth(item)
            item.frame = NSRect(x: x, y: Self.inset, width: w, height: Self.itemHeight)
            x += w + Self.inset
        }
    }

    // MARK: Shape

    /// Outline of the notch, y up: flush with the bottom and right edges, a
    /// rounded top-left corner, and concave fillets where it meets the pane's
    /// bottom edge (bottom-left) and right edge (top-right).
    static func outline(in size: NSSize) -> NSBezierPath {
        let w = size.width
        let h = bodyHeight
        let r = fillet
        let c = min(cornerRadius, h - r)
        let k: CGFloat = 0.552
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.curve(
            to: NSPoint(x: r, y: r), controlPoint1: NSPoint(x: k * r, y: 0),
            controlPoint2: NSPoint(x: r, y: r - k * r))
        path.line(to: NSPoint(x: r, y: h - c))
        path.curve(
            to: NSPoint(x: r + c, y: h), controlPoint1: NSPoint(x: r, y: h - c + k * c),
            controlPoint2: NSPoint(x: r + c - k * c, y: h))
        path.line(to: NSPoint(x: w - r, y: h))
        path.curve(
            to: NSPoint(x: w, y: h + r), controlPoint1: NSPoint(x: w - r + k * r, y: h),
            controlPoint2: NSPoint(x: w, y: h + r - k * r))
        path.line(to: NSPoint(x: w, y: 0))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        // The backdrop between islands, so the corner reads as cut out of the
        // pane; the pane strokes the cut's edge (`islandOutline`).
        AppSettings.shared.theme.windowBackdrop.setFill()
        Self.outline(in: bounds.size).fill()
    }

    /// The pane's island edge with the notch cut out of its bottom-right
    /// corner, in flipped pane coordinates, inset half a point for a 1pt
    /// stroke. Stands in for the layer border while the notch shows, so the
    /// edge runs around the cut instead of through it.
    static func islandOutline(paneSize: NSSize, notchWidth: CGFloat, radius: CGFloat) -> CGPath {
        let i: CGFloat = 0.5
        let right = paneSize.width - i
        let bottom = paneSize.height - i
        let x0 = paneSize.width - notchWidth
        let top = paneSize.height - bodyHeight
        let r = fillet
        let c = min(cornerRadius, bodyHeight - r)
        let k: CGFloat = 0.552
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: bottom))
        p.addCurve(
            to: CGPoint(x: x0 + r, y: bottom - r), control1: CGPoint(x: x0 + k * r, y: bottom),
            control2: CGPoint(x: x0 + r, y: bottom - r + k * r))
        p.addLine(to: CGPoint(x: x0 + r, y: top + c))
        p.addCurve(
            to: CGPoint(x: x0 + r + c, y: top), control1: CGPoint(x: x0 + r, y: top + c - k * c),
            control2: CGPoint(x: x0 + r + c - k * c, y: top))
        p.addLine(to: CGPoint(x: right - r, y: top))
        p.addCurve(
            to: CGPoint(x: right, y: top - r), control1: CGPoint(x: right - r + k * r, y: top),
            control2: CGPoint(x: right, y: top - r + k * r))
        p.addArc(tangent1End: CGPoint(x: right, y: i), tangent2End: CGPoint(x: i, y: i), radius: radius)
        p.addArc(tangent1End: CGPoint(x: i, y: i), tangent2End: CGPoint(x: i, y: bottom), radius: radius)
        p.addArc(tangent1End: CGPoint(x: i, y: bottom), tangent2End: CGPoint(x: x0, y: bottom), radius: radius)
        p.closeSubpath()
        return p
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bodyRect.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    // MARK: Menu

    /// The pane actions heading the ⋯ menu, nil marking a separator.
    static func primaryEntries(
        canRecord: Bool, isRecording: Bool, multiPane: Bool, isZoomed: Bool
    ) -> [PaneControlEntry?] {
        var entries: [PaneControlEntry?] = []
        if isRecording {
            entries.append(PaneControlEntry(action: .toggleRecording, title: "Stop Recording", symbol: "stop.circle"))
            entries.append(PaneControlEntry(action: .addMarker, title: "Add Marker", symbol: "bookmark"))
        } else if canRecord {
            entries.append(
                PaneControlEntry(action: .toggleRecording, title: "Start Recording", symbol: "record.circle"))
        }
        if !entries.isEmpty { entries.append(nil) }
        entries.append(PaneControlEntry(action: .splitRight, title: "Split Right", symbol: "rectangle.split.2x1"))
        entries.append(PaneControlEntry(action: .splitDown, title: "Split Down", symbol: "rectangle.split.1x2"))
        if multiPane {
            entries.append(
                isZoomed
                    ? PaneControlEntry(
                        action: .toggleZoom, title: "Show All Panes", symbol: "arrow.down.right.and.arrow.up.left")
                    : PaneControlEntry(
                        action: .toggleZoom, title: "Zoom Pane", symbol: "arrow.up.left.and.arrow.down.right"))
            entries.append(nil)
            entries.append(PaneControlEntry(action: .closePane, title: "Close Pane", symbol: "xmark.square"))
        }
        return entries
    }

    private func showMoreMenu() {
        guard let menu = menuProvider?() else { return }
        // Up and to the left, away from the pane's corner: the point is the
        // menu's top-left, so its bottom-right lands above the button.
        let size = menu.size
        menu.popUp(
            positioning: nil, at: NSPoint(x: more.frame.maxX - size.width, y: more.frame.maxY + 4 + size.height),
            in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recordChip.windowChanged(window != nil)
    }

    // Swallow clicks on the tab's padding so they don't fall through to the terminal.
    override func mouseDown(with event: NSEvent) {}
}

// MARK: - Buttons

/// Hover-tracking, clickable pill segment. Subclasses restyle in `hoverChanged()`.
class PaneControlItem: NSView {
    var onClick: (() -> Void)?
    private(set) var hovered = false { didSet { hoverChanged() } }
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PaneControlsView.itemCornerRadius
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func hoverChanged() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
    }

    override func mouseDown(with event: NSEvent) {
        hovered = false
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// Centers a 16pt icon frame in the item.
    var iconFrame: NSRect {
        let side: CGFloat = 16
        return NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
}

/// Icon button with hover highlight, sized by its container.
final class PaneControlButton: PaneControlItem {
    private let icon = NSImageView()
    private var symbol = ""

    init(symbol: String, help: String) {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        addSubview(icon)
        setSymbol(symbol, help: help)
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSymbol(_ symbol: String, help: String) {
        guard symbol != self.symbol else { return }
        self.symbol = symbol
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        toolTip = help
        setAccessibilityLabel(help)
    }

    func applyTheme() { hoverChanged() }

    override func hoverChanged() {
        let theme = AppSettings.shared.theme
        icon.contentTintColor = hovered ? theme.chromeText : theme.textSecondary
        layer?.backgroundColor = hovered ? theme.hoverFill.cgColor : nil
    }

    override func layout() {
        super.layout()
        icon.frame = iconFrame
    }
}

/// Record button that turns into a red dot plus elapsed time while recording.
/// Clicking it toggles recording.
final class RecordChip: PaneControlItem {
    var recordingSince: Date? {
        didSet {
            guard recordingSince != oldValue else { return }
            updateState()
        }
    }

    var onWidthChange: (() -> Void)?

    private static let inset: CGFloat = 8
    private static let dotSize: CGFloat = 7
    private static let gap: CGFloat = 5

    private let icon = NSImageView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var inWindow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        for view in [icon, dot, label] as [NSView] { addSubview(view) }
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() { hoverChanged() }

    func windowChanged(_ attached: Bool) {
        inWindow = attached
        updateTimer()
    }

    override var fittingSize: NSSize {
        let height: CGFloat = 20
        guard recordingSince != nil else { return NSSize(width: PaneControlsView.buttonWidth, height: height) }
        // Measured with every digit zeroed: digits are monospaced, so the pill
        // only grows when the format does (0:59 → 1:00:00), never each second.
        let sample = String(label.stringValue.map { $0.isNumber ? "0" : $0 })
        let width = (sample as NSString).size(withAttributes: [.font: label.font as Any]).width
        return NSSize(width: Self.inset + Self.dotSize + Self.gap + ceil(width) + Self.inset, height: height)
    }

    override func layout() {
        super.layout()
        icon.frame = iconFrame
        dot.frame = NSRect(
            x: Self.inset, y: (bounds.height - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize)
        let labelSize = label.intrinsicContentSize
        let labelX = dot.frame.maxX + Self.gap
        label.frame = NSRect(
            x: labelX, y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - labelX - Self.inset), height: labelSize.height)
    }

    private func updateState() {
        let recording = recordingSince != nil
        icon.isHidden = recording
        dot.isHidden = !recording
        label.isHidden = !recording
        if !recording { label.stringValue = "" }
        toolTip = recording ? "Stop Recording" : "Record Session"
        setAccessibilityLabel(toolTip)
        tick()
        updateTimer()
        hoverChanged()
    }

    private func updateTimer() {
        let needed = recordingSince != nil && inWindow
        if needed, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        guard let since = recordingSince else { return }
        let old = label.stringValue
        label.stringValue = CastPlayback.formatTime(Date().timeIntervalSince(since))
        if label.stringValue.count != old.count, !old.isEmpty { onWidthChange?() }
        setAccessibilityValue("Recording, \(label.stringValue)")
    }

    override func hoverChanged() {
        let theme = AppSettings.shared.theme
        icon.contentTintColor = hovered ? theme.error : theme.textSecondary
        dot.layer?.backgroundColor = theme.error.cgColor
        label.textColor = theme.error
        let recording = recordingSince != nil
        // Deliberate raw alpha: status-tinted chip, hover band when pointed at.
        let fill: NSColor? =
            recording
            ? theme.error.withAlphaComponent(hovered ? 0.22 : 0.14)
            : (hovered ? theme.hoverFill : nil)
        layer?.backgroundColor = fill?.cgColor
    }
}
