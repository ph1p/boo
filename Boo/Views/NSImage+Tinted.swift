import Cocoa

extension NSImage {
    /// A copy of this image at `size` with every opaque pixel painted `color`.
    func tinted(with color: NSColor, size: NSSize) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(
                in: rect, from: NSRect(origin: .zero, size: self.size),
                operation: .sourceOver, fraction: 1.0)
            // sourceAtop colors only the pixels the image already covers.
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
