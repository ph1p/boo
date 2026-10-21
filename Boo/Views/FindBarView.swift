import Cocoa

/// In-terminal find bar laid out like the system one (Safari, Terminal):
/// rounded search field with the match count and a clear button inside, a
/// joined previous/next control, and a Done button. Every colour is a theme token.
@MainActor final class FindBarView: NSView {
    var onSearch: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let textField = FindBarTextField()
    private let searchIcon = NSImageView()
    private let matchLabel = NSTextField(labelWithString: "")
    private let clearButton = FindBarButton(symbol: "xmark.circle.fill", help: "Clear Search", style: .glyph)
    private let fieldView = FindBarFieldView()
    private let stepper = FindBarStepper()
    private let doneButton = FindBarButton(title: "Done", help: "Close Find Bar")

    private var matchToClear: NSLayoutConstraint!
    private var matchToField: NSLayoutConstraint!

    static let height: CGFloat = 32
    /// System control height for regular-size search fields and buttons.
    private static let controlHeight: CGFloat = 22
    /// Room around the field for its focus stroke.
    private static let inset: CGFloat = FindBarFieldView.inset

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        let h = Self.controlHeight
        let inset = Self.inset

        fieldView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fieldView)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        fieldView.addSubview(searchIcon)

        textField.placeholderString = "Find"
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.cell?.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.setAccessibilityLabel("Find")
        textField.delegate = self
        textField.target = self
        textField.action = #selector(nextClicked)
        textField.onFocusGained = { [weak self] in self?.fieldView.isFocused = true }
        textField.onFocusLost = { [weak self] in self?.fieldView.isFocused = false }
        textField.translatesAutoresizingMaskIntoConstraints = false
        fieldView.addSubview(textField)

        matchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        matchLabel.alignment = .right
        matchLabel.setContentHuggingPriority(.required, for: .horizontal)
        matchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldView.addSubview(matchLabel)

        clearButton.isHidden = true
        clearButton.onClick = { [weak self] in self?.clearClicked() }
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        fieldView.addSubview(clearButton)

        stepper.onStep = { [weak self] next in self?.onNavigate?(next) }
        stepper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stepper)

        doneButton.onClick = { [weak self] in self?.onClose?() }
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneButton)

        matchToClear = matchLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4)
        matchToField = matchLabel.trailingAnchor.constraint(
            equalTo: fieldView.trailingAnchor, constant: -(inset + 9))

        NSLayoutConstraint.activate([
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.heightAnchor.constraint(equalToConstant: h),

            stepper.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.heightAnchor.constraint(equalToConstant: h),

            // The field's frame carries the stroke margin, so its visible edge
            // lines up with the 10pt / 8pt gutters the buttons use.
            fieldView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 - inset),
            fieldView.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -(8 - inset)),
            fieldView.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldView.heightAnchor.constraint(equalToConstant: h + 2 * inset),

            searchIcon.leadingAnchor.constraint(equalTo: fieldView.leadingAnchor, constant: inset + 7),
            searchIcon.centerYAnchor.constraint(equalTo: fieldView.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),

            textField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: fieldView.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -6),

            matchLabel.centerYAnchor.constraint(equalTo: fieldView.centerYAnchor),
            matchToField,

            clearButton.trailingAnchor.constraint(equalTo: fieldView.trailingAnchor, constant: -(inset + 4)),
            clearButton.centerYAnchor.constraint(equalTo: fieldView.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        updateMatches(selected: -1, total: -1)
        applyTheme()
    }

    func applyTheme() {
        let theme = AppSettings.shared.theme
        // Same surface as the pane, so the bar reads as part of the terminal.
        layer?.backgroundColor = theme.background.nsColor.cgColor
        fieldView.theme = theme
        textField.textColor = theme.chromeText
        textField.customPlaceholderColor = theme.textTertiary
        textField.caretColor = theme.cursor.nsColor
        textField.selectionColor = theme.selection
        searchIcon.contentTintColor = theme.textSecondary
        clearButton.applyTheme()
        stepper.applyTheme()
        doneButton.applyTheme()
        refreshMatchColor()
        needsDisplay = true
    }

    private var hasNoMatches = false

    private func refreshMatchColor() {
        let theme = AppSettings.shared.theme
        matchLabel.textColor = hasNoMatches ? theme.error : theme.textSecondary
        fieldView.hasError = hasNoMatches
    }

    private func refreshClearButton() {
        let empty = textField.stringValue.isEmpty
        guard clearButton.isHidden != empty else { return }
        clearButton.isHidden = empty
        matchToField.isActive = empty
        matchToClear.isActive = !empty
    }

    func focusField() {
        window?.makeFirstResponder(textField)
    }

    func updateMatches(selected: Int, total: Int) {
        if total < 0 {
            matchLabel.stringValue = ""
        } else if total == 0 {
            matchLabel.stringValue = "No results"
        } else {
            matchLabel.stringValue = selected < 0 ? "\(total)" : "\(selected + 1) of \(total)"
        }
        hasNoMatches = total == 0
        stepper.isEnabled = total > 0
        refreshMatchColor()
    }

    func clearField() {
        textField.stringValue = ""
        matchLabel.stringValue = ""
        hasNoMatches = false
        stepper.isEnabled = false
        refreshMatchColor()
        refreshClearButton()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hairline against the terminal below, like a system find bar's bottom edge.
        AppSettings.shared.theme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    private func clearClicked() {
        clearField()
        onSearch?("")
        focusField()
    }

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
        refreshClearButton()
        onSearch?(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)),
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        {
            onNavigate?(false)
            return true
        }
        return false
    }
}

// MARK: - FindBarFieldView

/// Rounded search-field surface. Focus strokes the edge with the theme
/// accent (like the file-tree filter); no matches tints it with the error colour.
private final class FindBarFieldView: NSView {
    static let inset: CGFloat = 1

    var theme: TerminalTheme? { didSet { needsDisplay = true } }
    var isFocused = false { didSet { needsDisplay = true } }
    var hasError = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let rect = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let field = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        theme.controlFill.setFill()
        field.fill()

        let strong = hasError || isFocused
        let edgeRect = rect.insetBy(dx: strong ? 0.5 : 0.25, dy: strong ? 0.5 : 0.25)
        let edge = NSBezierPath(roundedRect: edgeRect, xRadius: 6, yRadius: 6)
        edge.lineWidth = strong ? 1 : 0.5
        (hasError ? theme.error : isFocused ? theme.focusRing : theme.separator).setStroke()
        edge.stroke()
    }
}

// MARK: - FindBarStepper

/// Joined previous/next control: one rounded rect split by a hairline, like the
/// segmented arrows in the system find bars.
private final class FindBarStepper: NSView {
    var onStep: ((Bool) -> Void)?
    var isEnabled = true {
        didSet {
            prev.isEnabled = isEnabled
            next.isEnabled = isEnabled
        }
    }

    private let prev = FindBarButton(symbol: "chevron.left", help: "Previous Match", style: .segment)
    private let next = FindBarButton(symbol: "chevron.right", help: "Next Match", style: .segment)
    private let divider = NSView()
    private static let segmentWidth: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        divider.wantsLayer = true
        for v in [prev, next, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        prev.onClick = { [weak self] in self?.onStep?(false) }
        next.onClick = { [weak self] in self?.onStep?(true) }
        NSLayoutConstraint.activate([
            prev.leadingAnchor.constraint(equalTo: leadingAnchor),
            prev.topAnchor.constraint(equalTo: topAnchor),
            prev.bottomAnchor.constraint(equalTo: bottomAnchor),
            prev.widthAnchor.constraint(equalToConstant: Self.segmentWidth),
            divider.leadingAnchor.constraint(equalTo: prev.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            next.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
            next.widthAnchor.constraint(equalToConstant: Self.segmentWidth)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.controlFill.cgColor
        layer?.borderColor = theme.separator.cgColor
        layer?.borderWidth = 0.5
        divider.layer?.backgroundColor = theme.separator.cgColor
        prev.applyTheme()
        next.applyTheme()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 6
    }
}

// MARK: - FindBarButton

/// Hover-tracking button for the find bar: a stepper segment, a bare glyph
/// inside the field, or a titled push button.
private final class FindBarButton: PaneControlItem {
    enum Style { case segment, glyph, push }

    var isEnabled = true {
        didSet {
            setAccessibilityEnabled(isEnabled)
            hoverChanged()
        }
    }

    private let style: Style
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbol: String, help: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        icon.symbolConfiguration =
            style == .glyph ? .init(pointSize: 12, weight: .regular) : .init(pointSize: 11, weight: .semibold)
        addSubview(icon)
        configure(help: help)
    }

    init(title: String, help: String) {
        style = .push
        super.init(frame: .zero)
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        configure(help: help)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(help: String) {
        toolTip = help
        setAccessibilityLabel(help)
        layer?.cornerRadius = 0
        applyTheme()
    }

    func applyTheme() { hoverChanged() }

    override func hoverChanged() {
        let theme = AppSettings.shared.theme
        let lit = hovered && isEnabled
        switch style {
        case .segment:
            icon.contentTintColor = isEnabled ? theme.chromeText : theme.textTertiary
            layer?.backgroundColor = lit ? theme.hoverFill.cgColor : nil
        case .glyph:
            icon.contentTintColor = lit ? theme.textSecondary : theme.textTertiary
        case .push:
            label.textColor = theme.chromeText
            layer?.backgroundColor = (lit ? theme.separator : theme.controlFill).cgColor
            layer?.borderColor = theme.separator.cgColor
            layer?.borderWidth = 0.5
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return super.accessibilityPerformPress()
    }

    override func layout() {
        super.layout()
        if style == .push { layer?.cornerRadius = 6 }
        icon.frame = iconFrame
    }
}

// MARK: - FindBarTextField

private final class FindBarTextField: NSTextField {
    var onFocusGained: (() -> Void)?
    var onFocusLost: (() -> Void)?
    var customPlaceholderColor: NSColor? {
        didSet { updatePlaceholder() }
    }
    var caretColor: NSColor? { didSet { styleFieldEditor() } }
    var selectionColor: NSColor? { didSet { styleFieldEditor() } }

    private var focusObserver: NSObjectProtocol?

    private func updatePlaceholder() {
        guard let placeholder = placeholderString, let color = customPlaceholderColor else { return }
        placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: color,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
            ])
    }

    /// The shared field editor only exists while editing, so its caret and
    /// selection are themed each time focus arrives.
    private func styleFieldEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if let caretColor { editor.insertionPointColor = caretColor }
        if let selectionColor { editor.selectedTextAttributes = [.backgroundColor: selectionColor] }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            styleFieldEditor()
            onFocusGained?()
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // The observer is delivered on the main queue, so the main actor's
                // isolation holds even though the closure is typed @Sendable.
                MainActor.assumeIsolated {
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
        }
        return result
    }

}
