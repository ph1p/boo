import Cocoa

/// A thin tick at the left edge of each shell prompt in the viewport, red
/// when the command failed. Drawn over the terminal's padding; never takes
/// mouse events.
final class PromptGutterView: NSView {
    static let tickWidth: CGFloat = 2

    private var marks: [GhosttyView.PromptMark] = []
    private var cellHeight: CGFloat = 0
    private var padding = GhosttyView.defaultGridPadding
    private nonisolated(unsafe) var settingsObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(from view: GhosttyView) {
        let marks = view.promptMarks()
        let cellHeight = view.cellHeight ?? 0
        let padding = view.gridPadding
        guard marks != self.marks || cellHeight != self.cellHeight || padding != self.padding else { return }
        self.padding = padding
        self.marks = marks
        self.cellHeight = cellHeight
        needsDisplay = true
    }

    static func color(for status: GhosttyView.PromptMark.Status, theme: TerminalTheme) -> NSColor {
        switch status {
        case .failed: return theme.error
        case .succeeded: return theme.accentColor.withAlphaComponent(0.6)
        // Running, or the shell reported no exit status.
        case .none: return theme.focusBorder
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard cellHeight > 0, !marks.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = booTheme
        for mark in marks {
            let y = padding + CGFloat(mark.row) * cellHeight
            let rect = CGRect(x: 0, y: y, width: Self.tickWidth, height: cellHeight)
            guard rect.intersects(dirtyRect) else { continue }
            ctx.setFillColor(Self.color(for: mark.status, theme: theme).cgColor)
            ctx.fill(rect)
        }
    }
}
