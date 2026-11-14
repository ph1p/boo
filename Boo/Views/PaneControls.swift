import Cocoa

/// What a pane-controls item asks the window to do.
enum PaneControlAction {
    case toggleRecording
    case addMarker
    case splitRight
    case splitDown
    case toggleZoom
}

/// One pane action as the tab bar's ⋯ menu lists it.
struct PaneControlEntry: Equatable {
    let action: PaneControlAction
    let title: String
    let symbol: String
}

/// The pane actions the tab bar's ⋯ menu opens with.
enum PaneControls {
    /// The pane actions heading the ⋯ menu, nil marking a separator.
    /// Close Pane and the window-wide items follow them in the menu.
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
        }
        return entries
    }
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
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func hoverChanged() {}

    /// Subclasses style themselves in `hoverChanged()`, first without a
    /// window; restyle for the window's theme once there is one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { hoverChanged() }
    }

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
        let theme = booTheme
        icon.contentTintColor = hovered ? theme.chromeText : theme.textSecondary
        layer?.backgroundColor = hovered ? theme.hoverFill.cgColor : nil
    }

    override func layout() {
        super.layout()
        icon.frame = iconFrame
    }
}
