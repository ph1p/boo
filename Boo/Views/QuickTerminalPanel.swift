import Cocoa

/// Borderless panel that slides down from the top of the screen. It can
/// become key (so the terminal gets keys) but never main, so the main window
/// keeps its place in the responder chain behind the panel's delegate.
final class QuickTerminalPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: a tab strip (only with two or more tabs) above the
/// terminal container.
final class QuickTerminalContentView: NSView {
    static let stripHeight: CGFloat = 26

    let tabStrip = QuickTerminalTabStrip()
    let terminalContainer = NSView()
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        addSubview(terminalContainer)
        addSubview(tabStrip)
        applyTheme()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override var isFlipped: Bool { true }

    var showsTabs = false {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let strip = showsTabs ? Self.stripHeight : 0
        tabStrip.isHidden = !showsTabs
        tabStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
        terminalContainer.frame = NSRect(x: 0, y: strip, width: bounds.width, height: bounds.height - strip)
    }

    private func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.background.nsColor.cgColor
        layer?.borderColor = theme.paneBorder.cgColor
        tabStrip.needsDisplay = true
    }
}

/// Minimal tab strip: click selects, middle-click closes, "+" opens a tab.
final class QuickTerminalTabStrip: NSView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var activeIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private static let plusWidth: CGFloat = 28
    private static let maxTabWidth: CGFloat = 200

    override var isFlipped: Bool { true }

    private var tabWidth: CGFloat {
        guard !titles.isEmpty else { return 0 }
        return min(Self.maxTabWidth, (bounds.width - Self.plusWidth) / CGFloat(titles.count))
    }

    /// The tab under `x`, -1 for the "+" button, nil for empty strip space.
    func hit(x: CGFloat) -> Int? {
        let width = tabWidth
        let tabsEnd = width * CGFloat(titles.count)
        if x < tabsEnd, width > 0 { return Int(x / width) }
        if x >= tabsEnd, x < tabsEnd + Self.plusWidth { return -1 }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppSettings.shared.theme
        let width = tabWidth
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        for (index, title) in titles.enumerated() {
            let rect = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            let active = index == activeIndex
            if active {
                theme.controlFill.setFill()
                rect.insetBy(dx: 2, dy: 3).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .medium : .regular),
                .foregroundColor: active ? theme.chromeText : theme.textSecondary,
                .paragraphStyle: style
            ]
            let text = title as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(
                in: NSRect(
                    x: rect.minX + 8, y: (bounds.height - size.height) / 2, width: rect.width - 16, height: size.height),
                withAttributes: attrs)
        }
        let plus = "+" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: theme.textSecondary
        ]
        let size = plus.size(withAttributes: attrs)
        plus.draw(
            at: NSPoint(
                x: width * CGFloat(titles.count) + (Self.plusWidth - size.width) / 2,
                y: (bounds.height - size.height) / 2),
            withAttributes: attrs)
        theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let index = hit(x: x) else { return }
        if index < 0 { onNew?() } else { onSelect?(index) }
    }

    override func otherMouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if let index = hit(x: x), index >= 0 { onClose?(index) }
    }
}
