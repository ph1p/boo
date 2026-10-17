import Cocoa

/// Pill shown in the top-right corner of a zoomed pane: says the other panes
/// are hidden and unzooms on click.
final class ZoomBadgeView: NSView {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private static let height: CGFloat = 22
    private static let padding: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        icon.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        label.stringValue = "Zoomed  \u{21E7}\u{2318}\u{23CE}"
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        addSubview(icon)
        addSubview(label)
        toolTip = "Show all panes"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Zoomed pane. Show all panes")
        applyTheme()
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.dragGhostBg.cgColor
        layer?.borderColor = theme.focusBorder.cgColor
        label.textColor = theme.textSecondary
        icon.contentTintColor = theme.textSecondary
    }

    override var fittingSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: Self.padding * 2 + 12 + 4 + ceil(labelSize.width), height: Self.height)
    }

    override func layout() {
        super.layout()
        let labelSize = label.intrinsicContentSize
        icon.frame = NSRect(x: Self.padding, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(
            x: icon.frame.maxX + 4, y: (bounds.height - labelSize.height) / 2,
            width: ceil(labelSize.width), height: labelSize.height)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
