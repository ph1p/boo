import Cocoa

/// Borderless floating window that follows the cursor during a drag.
///
/// Drag events arrive unevenly (coalesced, or paused while the main thread is
/// busy), so setting the frame per event makes the ghost jump. Instead each
/// event only moves the target, and the window eases toward it once per
/// display frame.
@MainActor
final class DragGhostWindow: NSWindow {
    /// Share of the remaining distance covered per frame.
    nonisolated static let follow: CGFloat = 0.55
    /// Closer than this (points), the ghost snaps onto the target.
    nonisolated static let snapDistance: CGFloat = 0.5

    /// Fade duration when the ghost appears and when `fadeOut` dismisses it.
    nonisolated static let fadeDuration: TimeInterval = 0.12

    private var target: NSPoint
    /// Window origin relative to the cursor, kept for the whole drag so the ghost
    /// stays under the point where it was grabbed.
    private let anchor: NSPoint
    private var link: CADisplayLink?

    /// Shows `content` centered on `center` (screen coordinates).
    convenience init(content: NSView, center: NSPoint, alpha: CGFloat = 0.85) {
        let size = content.frame.size
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        self.init(content: content, origin: origin, cursor: center, alpha: alpha)
    }

    /// Shows `content` centered over `sourceFrame` (the dragged control, in screen
    /// coordinates), so the drag starts as that control lifting off; it then keeps
    /// its offset from `cursor` instead of snapping its center onto it.
    convenience init(content: NSView, sourceFrame: NSRect, cursor: NSPoint, alpha: CGFloat = 0.85) {
        let size = content.frame.size
        let origin = NSPoint(x: sourceFrame.midX - size.width / 2, y: sourceFrame.midY - size.height / 2)
        self.init(content: content, origin: origin, cursor: cursor, alpha: alpha)
    }

    private init(content: NSView, origin: NSPoint, cursor: NSPoint, alpha: CGFloat) {
        target = origin
        anchor = NSPoint(x: origin.x - cursor.x, y: origin.y - cursor.y)
        super.init(
            contentRect: NSRect(origin: origin, size: content.frame.size), styleMask: .borderless,
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true
        contentView = content
        alphaValue = 0
        orderFront(nil)
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = alpha
        }
    }

    /// Screen point of the event, or the current mouse location for events
    /// without a window.
    static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Follow the cursor at `cursor` (screen coordinates). For a ghost created
    /// with `init(content:center:)` that centers it on the cursor.
    func move(toCenter cursor: NSPoint) {
        target = NSPoint(x: cursor.x + anchor.x, y: cursor.y + anchor.y)
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let next = Self.eased(from: frame.origin, to: target)
        setFrameOrigin(next)
        if next == target { stopFollowing() }
    }

    override func orderOut(_ sender: Any?) {
        // The display link retains its target; drop it with the window.
        stopFollowing()
        super.orderOut(sender)
    }

    /// Fade out, then order out. Use when the drag ends; the window keeps itself
    /// alive until the fade finishes.
    func fadeOut() {
        stopFollowing()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
        }
    }

    private func stopFollowing() {
        link?.invalidate()
        link = nil
    }

    nonisolated static func eased(from origin: NSPoint, to target: NSPoint) -> NSPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        if abs(dx) < snapDistance && abs(dy) < snapDistance { return target }
        return NSPoint(x: origin.x + dx * follow, y: origin.y + dy * follow)
    }
}
