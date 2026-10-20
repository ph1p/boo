import Cocoa

/// What a pane-controls button asks the window to do.
enum PaneControlAction {
    case toggleRecording
    case splitRight
    case splitDown
    case toggleZoom
    case closePane
}

/// Floating pill in a pane's top-right corner: record, split, zoom, more, close.
/// Collapses to just the recording timer while the pane records and the
/// pointer is elsewhere, so a recording is never invisible.
final class PaneControlsView: NSView {
    static let height: CGFloat = 24
    private static let buttonWidth: CGFloat = 24
    private static let inset: CGFloat = 2

    var onAction: ((PaneControlAction) -> Void)?
    /// Builds the ⋯ menu on demand, so it always reflects current state.
    var menuProvider: (() -> NSMenu?)?

    private let recordChip = RecordChip()
    private let splitRight = PaneControlButton(symbol: "rectangle.split.2x1", help: "Split Right")
    private let splitDown = PaneControlButton(symbol: "rectangle.split.1x2", help: "Split Down")
    private let zoom = PaneControlButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom Pane")
    private let more = PaneControlButton(symbol: "ellipsis", help: "More")
    private let close = PaneControlButton(symbol: "xmark", help: "Close Pane")

    /// Whether the full set of buttons shows, or only the recording timer.
    private(set) var isExpanded = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        recordChip.onClick = { [weak self] in self?.onAction?(.toggleRecording) }
        splitRight.onClick = { [weak self] in self?.onAction?(.splitRight) }
        splitDown.onClick = { [weak self] in self?.onAction?(.splitDown) }
        zoom.onClick = { [weak self] in self?.onAction?(.toggleZoom) }
        close.onClick = { [weak self] in self?.onAction?(.closePane) }
        more.onClick = { [weak self] in self?.showMoreMenu() }
        for view in [recordChip, splitRight, splitDown, zoom, more, close] as [NSView] { addSubview(view) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane Controls")
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.dragGhostBg.cgColor
        layer?.borderColor = theme.focusBorder.cgColor
        for button in [splitRight, splitDown, zoom, more, close] { button.applyTheme() }
        recordChip.applyTheme()
    }

    /// Updates which buttons exist and whether the recording timer runs.
    func configure(
        expanded: Bool, canRecord: Bool, recordingSince: Date?, canZoom: Bool, canClose: Bool
    ) {
        isExpanded = expanded
        recordChip.recordingSince = recordingSince
        recordChip.isHidden = !(canRecord || recordingSince != nil)
        for button in [splitRight, splitDown, more] { button.isHidden = !expanded }
        zoom.isHidden = !(expanded && canZoom)
        close.isHidden = !(expanded && canClose)
        setFrameSize(fittingSize)
        needsLayout = true
    }

    /// True when there is nothing to show — collapsed and not recording.
    var isEmpty: Bool { !isExpanded && recordChip.recordingSince == nil }

    private var visibleItems: [NSView] {
        [recordChip, splitRight, splitDown, zoom, more, close].filter { !$0.isHidden }
    }

    override var fittingSize: NSSize {
        let width = visibleItems.reduce(Self.inset * 2) { $0 + itemWidth($1) }
        return NSSize(width: width, height: Self.height)
    }

    private func itemWidth(_ view: NSView) -> CGFloat {
        view === recordChip ? recordChip.fittingSize.width : Self.buttonWidth
    }

    override func layout() {
        super.layout()
        var x = Self.inset
        for view in visibleItems {
            let w = itemWidth(view)
            view.frame = NSRect(x: x, y: Self.inset, width: w, height: Self.height - Self.inset * 2)
            x += w
        }
    }

    /// Zoom icon flips with state; the badge handles unzoom, but keep it honest.
    func setZoomed(_ zoomed: Bool) {
        zoom.setSymbol(
            zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            help: zoomed ? "Show All Panes" : "Zoom Pane")
    }

    private func showMoreMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 4), in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recordChip.windowChanged(window != nil)
    }

    // Swallow clicks on the pill's padding so they don't fall through to the terminal.
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
        layer?.cornerRadius = (PaneControlsView.height - 4) / 2
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

    /// Centers a 14pt icon frame in the item.
    var iconFrame: NSRect {
        let side: CGFloat = 14
        return NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
}

/// Icon button with hover highlight, sized by its container.
final class PaneControlButton: PaneControlItem {
    private let icon = NSImageView()
    private var symbol = ""

    init(symbol: String, help: String) {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
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

    private let icon = NSImageView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var inWindow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .systemRed
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
        guard recordingSince != nil else { return NSSize(width: 24, height: PaneControlsView.height - 4) }
        // Sized for the widest label in its range, so the pill doesn't jitter each second.
        let sample = label.stringValue.count > 5 ? "00:00:00" : "00:00"
        let width = (sample as NSString).size(withAttributes: [.font: label.font as Any]).width
        return NSSize(width: 8 + 7 + 5 + ceil(width) + 8, height: PaneControlsView.height - 4)
    }

    override func layout() {
        super.layout()
        icon.frame = iconFrame
        dot.frame = NSRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(
            x: dot.frame.maxX + 5, y: (bounds.height - labelSize.height) / 2,
            width: bounds.width - dot.frame.maxX - 5 - 6, height: labelSize.height)
    }

    private func updateState() {
        let recording = recordingSince != nil
        icon.isHidden = recording
        dot.isHidden = !recording
        label.isHidden = !recording
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
        label.stringValue = CastPlayback.formatTime(Date().timeIntervalSince(since))
        setAccessibilityValue("Recording, \(label.stringValue)")
    }

    override func hoverChanged() {
        let theme = AppSettings.shared.theme
        icon.contentTintColor = hovered ? .systemRed : theme.textSecondary
        let recording = recordingSince != nil
        let fill: NSColor? =
            recording
            ? NSColor.systemRed.withAlphaComponent(hovered ? 0.22 : 0.14)
            : (hovered ? theme.hoverFill : nil)
        layer?.backgroundColor = fill?.cgColor
    }
}
