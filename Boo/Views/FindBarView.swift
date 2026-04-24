import Cocoa

@MainActor final class FindBarView: NSView {
    var onSearch: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let textField = FindBarTextField()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let matchLabel = NSTextField(labelWithString: "")
    private let pillView = FindBarPillView()

    static let height: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        applyTheme()

        // Pill container behind the text field
        pillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillView)

        // Text field inside the pill
        textField.placeholderString = "Find…"
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.delegate = self
        textField.target = self
        textField.action = #selector(nextClicked)
        textField.onFocusGained = { [weak self] in self?.pillView.isFocused = true }
        textField.onFocusLost = { [weak self] in self?.pillView.isFocused = false }
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        // Match count label
        matchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        matchLabel.alignment = .right
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(matchLabel)

        // Prev/next buttons
        configureIconButton(prevButton, symbol: "chevron.up", action: #selector(prevClicked))
        configureIconButton(nextButton, symbol: "chevron.down", action: #selector(nextClicked))
        configureIconButton(closeButton, symbol: "xmark", action: #selector(closeClicked))

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 22),

            prevButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 22),
            prevButton.heightAnchor.constraint(equalToConstant: 22),

            matchLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -8),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pillView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillView.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -6),
            pillView.heightAnchor.constraint(equalToConstant: 22),

            textField.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -8)
        ])

        applyThemeToControls()
    }

    private func configureIconButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }

    func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.chromeBg.cgColor
        pillView.theme = theme
        applyThemeToControls()
    }

    private func applyThemeToControls() {
        let theme = AppSettings.shared.theme
        textField.textColor = theme.chromeText
        textField.customPlaceholderColor = theme.chromeMuted.withAlphaComponent(0.6)
        matchLabel.textColor = theme.chromeMuted
        let mutedTint = theme.chromeMuted
        prevButton.contentTintColor = mutedTint
        nextButton.contentTintColor = mutedTint
        closeButton.contentTintColor = mutedTint
    }

    func focusField() {
        window?.makeFirstResponder(textField)
    }

    func updateMatches(selected: Int, total: Int) {
        let theme = AppSettings.shared.theme
        if total < 0 {
            matchLabel.stringValue = ""
        } else if total == 0 {
            matchLabel.stringValue = "No results"
            matchLabel.textColor = .systemRed
        } else {
            matchLabel.stringValue = selected < 0 ? "\(total)" : "\(selected + 1)/\(total)"
            matchLabel.textColor = theme.chromeMuted
        }
    }

    func clearField() {
        textField.stringValue = ""
        matchLabel.stringValue = ""
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Top separator line
        let theme = AppSettings.shared.theme
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func prevClicked() { onNavigate?(false) }
    @objc private func nextClicked() { onNavigate?(true) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearch?(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}

// MARK: - FindBarPillView

private final class FindBarPillView: NSView {
    var theme: TerminalTheme? { didSet { needsDisplay = true } }
    var isFocused: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let radius = bounds.height / 2
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        theme.sidebarBg.setFill()
        path.fill()
        if isFocused {
            theme.accentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
        } else {
            theme.chromeMuted.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 0.5
        }
        path.stroke()
    }
}

// MARK: - FindBarTextField

private final class FindBarTextField: NSTextField {
    var onFocusGained: (() -> Void)?
    var onFocusLost: (() -> Void)?
    var customPlaceholderColor: NSColor? {
        didSet { updatePlaceholder() }
    }

    private var focusObserver: NSObjectProtocol?

    private func updatePlaceholder() {
        guard let placeholder = placeholderString, let color = customPlaceholderColor else { return }
        placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: color,
                .font: font ?? NSFont.systemFont(ofSize: 12)
            ])
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusGained?()
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                guard let win = self.window else { return }
                let fr = win.firstResponder
                let isActive = fr === self || (fr is NSTextView && (fr as? NSTextView)?.delegate === self)
                if !isActive {
                    self.onFocusLost?()
                    if let obs = self.focusObserver {
                        NotificationCenter.default.removeObserver(obs)
                        self.focusObserver = nil
                    }
                }
            }
        }
        return result
    }

}
