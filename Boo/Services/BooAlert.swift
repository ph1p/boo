import Cocoa

/// Centralised error feedback for Boo.
///
/// - ``showTransient(_:)`` — lightweight overlay that auto-dismisses (clipboard, file ops).
/// - ``showError(title:message:window:)`` — modal alert for critical failures (bootstrap).
@MainActor
enum BooAlert {

    // MARK: - Transient Overlay

    /// Show a brief message overlay at the bottom of the key window, fading out
    /// after ~2.5 seconds.  Follows the `flashTerminal()` animation pattern.
    static func showTransient(_ message: String) {
        guard let window = NSApp.keyWindow,
            let contentView = window.contentView
        else { return }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        label.isBordered = false
        label.drawsBackground = true
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.sizeToFit()

        // Add horizontal padding.
        let padding: CGFloat = 24
        var frame = label.frame
        frame.size.width += padding
        frame.size.height += 12
        frame.origin.x = (contentView.bounds.width - frame.width) / 2
        frame.origin.y = 24
        label.frame = frame

        contentView.addSubview(label)
        label.alphaValue = 0

        // Fade in.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            label.animator().alphaValue = 1
        }

        // Fade out after delay, then remove.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                label.animator().alphaValue = 0
            }) {
                label.removeFromSuperview()
            }
        }
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
