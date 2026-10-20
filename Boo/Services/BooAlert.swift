import Cocoa

/// Centralised error feedback for Boo.
///
/// - ``showTransient(_:)`` — lightweight overlay that auto-dismisses (clipboard, file ops).
/// - ``showError(title:message:window:)`` — modal alert for critical failures (bootstrap).
@MainActor
enum BooAlert {

    // MARK: - Transient Overlay

    /// Bubbles currently on screen, oldest first — used to stack them instead of
    /// drawing every message on top of the last one.  Each entry keeps the
    /// bottom-pin constraint so the stack can be re-flowed as toasts come and go.
    private static var liveToasts: [(view: NSView, bottom: NSLayoutConstraint)] = []

    private static let toastSpacing: CGFloat = 8
    private static let toastBottomInset: CGFloat = 24
    private static let toastLifetime: TimeInterval = 2.5
    /// Toasts with buttons stay longer — they ask for a decision, not a glance.
    private static let actionToastLifetime: TimeInterval = 7

    /// A button on a transient toast; clicking it runs `handler` and dismisses the toast.
    struct ToastAction {
        let title: String
        let handler: () -> Void
    }

    /// Show a brief message bubble at the bottom of the key window, fading out
    /// after ~2.5 seconds.  Follows the `flashTerminal()` animation pattern.
    static func showTransient(_ message: String, actions: [ToastAction] = []) {
        guard let window = NSApp.keyWindow,
            let contentView = window.contentView
        else { return }

        // The bubble is its own container so the label can be centred inside it
        // with constraints — an `NSTextField` draws single-line text near the top
        // of its cell, so padding it directly leaves the text sitting high.
        let bubble = NSVisualEffectView()
        bubble.material = .hudWindow
        bubble.blendingMode = .withinWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.masksToBounds = true
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Shadow needs a wrapper: `masksToBounds` on the bubble clips its own.
        let shell = NSView()
        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.shadow = NSShadow()
        shell.layer?.shadowColor = NSColor.black.cgColor
        shell.layer?.shadowOpacity = 0.28
        shell.layer?.shadowRadius = 12
        shell.layer?.shadowOffset = CGSize(width: 0, height: -3)

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        // With actions the label and its buttons share one row.
        let content: NSView
        if actions.isEmpty {
            content = label
        } else {
            let buttons = actions.map { item in
                ToastActionButton(title: item.title) {
                    item.handler()
                    dismissToast(shell, in: contentView)
                }
            }
            let row = NSStackView(views: [label] + buttons)
            row.orientation = .horizontal
            row.spacing = 10
            row.setCustomSpacing(14, after: label)
            row.translatesAutoresizingMaskIntoConstraints = false
            content = row
        }

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        shell.addSubview(bubble)
        contentView.addSubview(shell)

        let width = content.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8)
        width.priority = .required

        // Animated via its `constant`, not `setFrameOrigin` — under Auto Layout a
        // frame nudge is undone by the next layout pass.
        let bottom = shell.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -toastBottomInset
        )

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: shell.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            bubble.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: shell.trailingAnchor),

            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9),
            content.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            width,

            // Centred and pinned to the bottom, so it tracks window resizing.
            shell.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bottom
        ])

        liveToasts.append((shell, bottom))
        contentView.layoutSubtreeIfNeeded()

        // Slide in from just below its resting spot, and lift the older bubbles.
        bottom.constant = -toastBottomInset + 12
        contentView.layoutSubtreeIfNeeded()
        shell.alphaValue = 0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            shell.animator().alphaValue = 1
            reflowToasts(in: contentView)
        }

        // Fade out after delay, then remove and close the gap.
        let lifetime = actions.isEmpty ? toastLifetime : actionToastLifetime
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            dismissToast(shell, in: contentView)
        }
    }

    /// Fades a toast out and closes its gap; a no-op once it's gone.
    private static func dismissToast(_ shell: NSView, in contentView: NSView) {
        guard liveToasts.contains(where: { $0.view === shell }) else { return }
        liveToasts.removeAll { $0.view === shell }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            shell.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated {
                shell.removeFromSuperview()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.allowsImplicitAnimation = true
                    reflowToasts(in: contentView)
                }
            }
        }
    }

    /// Re-pin every live bubble so the newest sits at the bottom and the older
    /// ones stack upwards, closing any gap left by a dismissed one.
    private static func reflowToasts(in contentView: NSView) {
        var offset = toastBottomInset
        for (view, bottom) in liveToasts.reversed() {
            bottom.constant = -offset
            offset += view.frame.height + toastSpacing
        }
        contentView.layoutSubtreeIfNeeded()
    }

    // MARK: - Modal Alert

    /// Show a warning alert, as a sheet if a window is available.
    static func showError(title: String, message: String, window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let w = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: w)
        } else {
            alert.runModal()
        }
    }
}

/// Link-style button on a toast, backed by a closure.
private final class ToastActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor
            ])
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { handler() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
