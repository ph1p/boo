import AppKit
import ObjectiveC

@MainActor
enum TrafficLightPositioner {
    /// Shift from the native traffic-light origins to their place in the toolbar
    /// island. Derived from the close button rather than hand-tuned: its centre
    /// sits on the island's vertical centre, and its gap to the island's leading
    /// edge equals its gap to the island's top, so the cluster reads as centred in
    /// the island corner whatever the toolbar height. Zero until laid out.
    /// Gap between the close button and the toolbar island's top and leading edge.
    static func edgeInset(buttonHeight: CGFloat) -> CGFloat {
        (IslandMetrics.toolbarHeight - buttonHeight) / 2
    }

    private static func offset(for window: NSWindow, entry: Entry) -> NSPoint {
        guard let close = window.standardWindowButton(.closeButton),
            let superview = close.superview,
            let content = window.contentView
        else { return .zero }
        let nativeOrigin = entry.nativeOrigins[ObjectIdentifier(close)] ?? close.frame.origin
        guard nativeOrigin.x != 0 || nativeOrigin.y != 0 else { return .zero }
        let native = superview.convert(nativeOrigin, to: nil)
        let size = close.frame.size
        let inset = edgeInset(buttonHeight: size.height)
        let toolbarTop = content.convert(NSPoint(x: 0, y: content.bounds.maxY), to: nil).y - IslandMetrics.barGap
        let target = NSPoint(
            x: IslandMetrics.gap + inset,
            y: toolbarTop - IslandMetrics.toolbarHeight / 2 - size.height / 2)
        return NSPoint(x: (target.x - native.x).rounded(), y: (target.y - native.y).rounded())
    }

    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton
    ]

    private final class Entry {
        var closeObserver: NSObjectProtocol?
        var nativeOrigins: [ObjectIdentifier: NSPoint] = [:]
        weak var window: NSWindow?
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    // O(1) lookup: button objectID → owning entry (populated on first intercept/attach)
    private static var buttonToEntry: [ObjectIdentifier: Entry] = [:]

    // MARK: – Public API

    static func attach(to window: NSWindow) {
        NSButtonSwizzle.install()
        let key = ObjectIdentifier(window)
        guard entries[key] == nil else { return }

        let entry = Entry()
        entry.window = window
        entries[key] = entry

        // Seed buttonToEntry immediately so the swizzle can early-exit non-traffic-light buttons.
        for type in buttonTypes {
            if let btn = window.standardWindowButton(type) {
                buttonToEntry[ObjectIdentifier(btn)] = entry
            }
        }

        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { detach(window) }
        }
        entry.closeObserver = obs

        apply(to: window)
    }

    static func apply(to window: NSWindow) {
        guard let entry = entries[ObjectIdentifier(window)],
            let w = entry.window,
            !w.styleMask.contains(.fullScreen)
        else { return }
        for type in buttonTypes {
            guard let btn = w.standardWindowButton(type) else { continue }
            shift(btn, entry: entry)
        }
    }

    // MARK: – Called from swizzled setFrameOrigin (main thread only)

    nonisolated static func interceptedSetFrameOrigin(
        button: NSButton, proposed: NSPoint
    ) -> NSPoint? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            _intercept(button: button, proposed: proposed)
        }
    }

    private static func _intercept(button: NSButton, proposed: NSPoint) -> NSPoint? {
        guard proposed.x != 0 || proposed.y != 0 else { return nil }
        let id = ObjectIdentifier(button)
        // Fast path: most NSButton instances in the app are not traffic lights.
        guard let entry = buttonToEntry[id] else { return nil }
        guard let window = entry.window, !window.styleMask.contains(.fullScreen) else { return nil }
        // A set to the already-shifted origin is our own `shift()` (or AppKit
        // echoing the current frame), not a fresh native layout — treating it as
        // native would stack the offset once per pass.
        let off = offset(for: window, entry: entry)
        if let native = entry.nativeOrigins[id],
            proposed == NSPoint(x: native.x + off.x, y: native.y + off.y)
        {
            return nil
        }
        entry.nativeOrigins[id] = proposed
        let next = offset(for: window, entry: entry)
        return NSPoint(x: proposed.x + next.x, y: proposed.y + next.y)
    }

    // MARK: – Helpers

    private static func shift(_ btn: NSButton, entry: Entry) {
        let origin = btn.frame.origin
        guard origin.x != 0 || origin.y != 0 else { return }
        let id = ObjectIdentifier(btn)
        let native: NSPoint
        if let stored = entry.nativeOrigins[id] {
            native = stored
        } else {
            // Swizzle hasn't intercepted this button yet — treat current origin as native.
            native = origin
            entry.nativeOrigins[id] = native
        }
        guard let window = entry.window else { return }
        let off = offset(for: window, entry: entry)
        let target = NSPoint(x: native.x + off.x, y: native.y + off.y)
        guard btn.frame.origin != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        btn.setFrameOrigin(target)
        CATransaction.commit()
    }

    private static func detach(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let entry = entries.removeValue(forKey: key) else { return }
        // Clean up buttonToEntry for this window's buttons.
        for type in buttonTypes {
            if let btn = window.standardWindowButton(type) {
                buttonToEntry.removeValue(forKey: ObjectIdentifier(btn))
            }
        }
        if let obs = entry.closeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: – Swizzle

// Replaces NSButton.setFrameOrigin with a block IMP that captures the original
// IMP and calls it directly — avoids the infinite-recursion trap of
// method_exchangeImplementations + super.
private enum NSButtonSwizzle {
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        let cls: AnyClass = NSButton.self
        let sel = #selector(NSButton.setFrameOrigin(_:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let originalIMP = method_getImplementation(method)

        typealias SetFrameOriginIMP = @convention(c) (AnyObject, Selector, NSPoint) -> Void
        let origFn = unsafeBitCast(originalIMP, to: SetFrameOriginIMP.self)

        let block: @convention(block) (NSButton, NSPoint) -> Void = { btn, proposed in
            if let redirected = TrafficLightPositioner.interceptedSetFrameOrigin(
                button: btn, proposed: proposed
            ) {
                origFn(btn, sel, redirected)
            } else {
                origFn(btn, sel, proposed)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
