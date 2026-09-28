import CObjCSafe
import Cocoa

extension NSString {
    /// `draw(at:withAttributes:)` that skips the text for this frame if AppKit raises an
    /// Objective-C exception. Swift can't catch those, and an uncaught one on the main
    /// thread kills the app (seen in 1.29.5 from CoreText font fallback in the status bar).
    func safeDraw(at point: NSPoint, withAttributes attrs: [NSAttributedString.Key: Any]) {
        _ = BooSafeDrawString(self as String, point, attrs)
    }

    /// `size(withAttributes:)` that returns `.zero` if AppKit raises.
    func safeSize(withAttributes attrs: [NSAttributedString.Key: Any]) -> NSSize {
        BooSafeStringSize(self as String, attrs)
    }
}
