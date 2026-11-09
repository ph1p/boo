import Cocoa

/// Strip across the top of a tmux pane whose output tmux paused (flow
/// control, `tmuxPauseAfterSeconds`). Unpause asks tmux to send it again.
final class TmuxPausedBar: NSView {
    static let height: CGFloat = 28

    var onUnpause: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        autoresizingMask = [.width, .minYMargin]

        let label = NSTextField(labelWithString: "tmux paused this pane: Boo fell behind its output.")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Unpause", target: self, action: #selector(unpause))
        button.bezelStyle = .rounded
        button.controlSize = .small

        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func unpause() { onUnpause?() }

    /// Shows (or removes) the bar on `pane`.
    static func set(_ shown: Bool, on pane: NSView, unpause: @escaping () -> Void) {
        let existing = pane.subviews.first { $0 is TmuxPausedBar }
        guard shown else { return existing?.removeFromSuperview() ?? () }
        guard existing == nil else { return }
        let bar = TmuxPausedBar(
            frame: NSRect(
                x: 0, y: pane.isFlipped ? 0 : pane.bounds.height - height, width: pane.bounds.width, height: height))
        if pane.isFlipped { bar.autoresizingMask = [.width, .maxYMargin] }
        bar.onUnpause = unpause
        pane.addSubview(bar, positioned: .above, relativeTo: nil)
    }
}
