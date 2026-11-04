import Cocoa

// MARK: - NavHoverButton

/// Square toolbar button with a rounded-rect hover background.
/// Uses a layer-backed NSImageView for the icon so NSButton's cell never clips it.
final class NavHoverButton: NSView {
    /// Placeholder only — every creation path sets this from the theme
    /// (`makeNavButton`) and `applyTheme` re-sets it on theme change.
    var hoverBackground: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    var contentTintColor: NSColor? {
        didSet { imageView.contentTintColor = contentTintColor }
    }

    var image: NSImage? {
        didSet { imageView.image = image }
    }

    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    var target: AnyObject?
    var action: Selector?

    private let imageView = NSImageView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }
}

// MARK: - URLBarPillView

/// Rounded-rect pill behind the URL text field.
/// Draws a focus ring around itself when the embedded field is first responder.
final class URLBarPillView: NSView {
    var theme: TerminalTheme? { didSet { needsDisplay = true } }
    /// Called by the text field's delegate to toggle focused appearance.
    var isFocused: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let radius = bounds.height / 2
        let inset = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        theme.subtleFill.setFill()
        path.fill()

        // Border: subtle when idle, focus ring when editing
        if isFocused {
            theme.focusRing.setStroke()
            path.lineWidth = 1.5
        } else {
            theme.separator.setStroke()
            path.lineWidth = 0.5
        }
        path.stroke()
    }
}

// MARK: - BrowserProgressView

/// Thin load-progress line along the bottom of the browser toolbar.
final class BrowserProgressView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    /// nil hides the bar.
    var progress: Double? {
        didSet {
            guard progress != oldValue else { return }
            isHidden = progress == nil
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let progress else { return }
        color.setFill()
        // Never fully empty: a just-started load still shows it is working.
        NSRect(x: 0, y: 0, width: bounds.width * max(0.08, min(progress, 1)), height: bounds.height).fill()
    }
}

// MARK: - SelectAllTextField

/// NSTextField that:
/// - Calls `onFocusGained` immediately when it becomes first responder (click or Tab).
/// - Selects all text on the next run loop tick (field editor is installed by then).
/// - Watches `NSApplication.didUpdateNotification` to detect when focus leaves
///   (works on macOS 13+; `NSWindow.firstResponderDidChangeNotification` needs 14+).
/// - Calls `onFocusLost` and clears the observer when another view takes focus.
final class SelectAllTextField: NSTextField {
    var onFocusGained: (() -> Void)?
    var onFocusLost: (() -> Void)?

    private var focusObserver: NSObjectProtocol?
    var isFieldActive = false

    // True between becomeFirstResponder and the first mouseDown that follows.
    // When a click causes focus, becomeFirstResponder fires before mouseDown —
    // this flag lets mouseDown know whether it's the focus-gaining click or a
    // subsequent click on an already-focused field.
    var justBecameFirstResponder = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        guard result else { return false }

        justBecameFirstResponder = true
        isFieldActive = true
        onFocusGained?()

        // For Tab / programmatic focus there is no mouseDown, so select-all must
        // happen here. For click-focus, mouseDown will fire synchronously on the
        // same run-loop iteration and clear justBecameFirstResponder — the async
        // block then skips the selectAll to avoid fighting the cursor placement
        // that super.mouseDown already performed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.justBecameFirstResponder else { return }
            self.justBecameFirstResponder = false
            self.currentEditor()?.selectAll(nil)
        }

        if let obs = focusObserver {
            NotificationCenter.default.removeObserver(obs)
            focusObserver = nil
        }

        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let fr = window.firstResponder
                let fieldEditorOwnedByUs = (fr as? NSTextView)?.delegate as? NSTextField === self
                if fr !== self && !fieldEditorOwnedByUs {
                    self.isFieldActive = false
                    self.onFocusLost?()
                    if let obs = self.focusObserver {
                        NotificationCenter.default.removeObserver(obs)
                        self.focusObserver = nil
                    }
                }
            }
        }

        return true
    }

    override func mouseDown(with event: NSEvent) {
        if justBecameFirstResponder {
            // This click caused focus. Don't call super — it would run a blocking
            // mouse-tracking loop and place the cursor, overriding the selection.
            // becomeFirstResponder already installed the field editor; just select all.
            justBecameFirstResponder = false
            currentEditor()?.selectAll(nil)
        } else {
            // Field was already focused — normal cursor placement.
            super.mouseDown(with: event)
        }
    }
}
