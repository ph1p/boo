import Cocoa

/// Covers the terminal running `tmux -CC` while Boo drives it: the terminal
/// only carries the control protocol, so it lists the session's windows,
/// which open as workspaces, and offers the ways out instead of looking frozen.
@MainActor
final class TmuxGatewayOverlay: NSView {
    var onShowWindow: ((UUID) -> Void)?
    var onNewWindow: (() -> Void)?
    var onDetach: (() -> Void)?

    private let status = NSTextField(labelWithString: "Connecting to tmux…")
    private let list = NSStackView()
    private var windows: [UUID] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "tmux control mode")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.isHidden = true

        let newWindow = NSButton(title: "New Window", target: self, action: #selector(newWindowTapped))
        let detach = NSButton(title: "Detach", target: self, action: #selector(detachTapped))
        let buttons = NSStackView(views: [newWindow, detach])
        buttons.spacing = 8

        let hint = NSTextField(labelWithString: "Esc or q detaches. tmux keeps running.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, title, status, list, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(14, after: status)
        stack.setCustomSpacing(14, after: list)
        stack.setCustomSpacing(10, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 300)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preferredWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("tmux control mode")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `session` and one row per window; a row opens its workspace.
    func update(session: String?, windows: [(workspace: UUID, name: String)]) {
        if let session {
            let count = windows.count == 1 ? "1 window" : "\(windows.count) windows"
            status.stringValue = "Session \(session) · \(count)"
        }
        // Rows past nine would push the buttons off a small pane.
        let shown = windows.prefix(9)
        self.windows = shown.map(\.workspace)
        for row in list.arrangedSubviews { row.removeFromSuperview() }
        for (n, window) in shown.enumerated() {
            let row = NSButton(title: window.name, target: self, action: #selector(windowTapped(_:)))
            row.tag = n
            row.bezelStyle = .recessed
            row.showsBorderOnlyWhileMouseInside = true
            row.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            row.imagePosition = .imageLeading
            row.alignment = .left
            row.lineBreakMode = .byTruncatingTail
            row.toolTip = "Show “\(window.name)”"
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.isHidden = shown.isEmpty
    }

    // Clicks stay off the terminal below but still focus it, so Esc and q work.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview)
    }

    @objc private func windowTapped(_ sender: NSButton) {
        guard windows.indices.contains(sender.tag) else { return }
        onShowWindow?(windows[sender.tag])
    }

    @objc private func newWindowTapped() { onNewWindow?() }
    @objc private func detachTapped() { onDetach?() }
}
