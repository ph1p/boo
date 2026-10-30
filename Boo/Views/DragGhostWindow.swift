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

    private var target: NSPoint
    private var link: CADisplayLink?

    /// Shows `content` centered on `center` (screen coordinates).
    init(content: NSView, center: NSPoint, alpha: CGFloat = 1) {
        let size = content.frame.size
        target = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        super.init(
            contentRect: NSRect(origin: target, size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        contentView = content
        alphaValue = alpha
        orderFront(nil)
    }

    /// Screen point of the event, or the current mouse location for events
    /// without a window.
    static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func move(toCenter center: NSPoint) {
        target = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
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
