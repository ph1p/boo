import Cocoa

/// NSSplitView with themed divider color and a VS Code-style accent hover highlight.
class ThemedSplitView: NSSplitView {
    var onDividerDoubleClick: (() -> Void)?
    /// Called after the user releases a divider they dragged.
    var onDividerDragEnded: (() -> Void)?

    /// Share of the space (minus the divider) given to the first subview.
    /// Owned by `SplitContainerView`, which lays out from it.
    var ratio: CGFloat = 0.5

    /// True while AppKit tracks a divider drag inside `mouseDown`.
    private(set) var isDraggingDivider = false

    /// In the island style the divider *is* the gap between two islands, so it
    /// matches the window backdrop rather than drawing a border line.
    override var dividerColor: NSColor {
        AppSettings.shared.theme.windowBackdrop
    }

    /// Widen the divider to the island gap so panes (and the sidebar) are spaced
    /// exactly like every other island.
    override var dividerThickness: CGFloat {
        IslandMetrics.gap
    }

    private var dividerHoverHighlighted = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil))
    }

    /// The primary divider's full strip (`dividerThickness` wide, from the first
    /// subview's trailing edge), padded by the 2pt slop the double-click hit test uses.
    private func primaryDividerStrip() -> CGRect? {
        guard subviews.count >= 2 else { return nil }
        if isVertical {
            return CGRect(
                x: subviews[0].frame.maxX, y: 0,
                width: dividerThickness, height: bounds.height
            ).insetBy(dx: -2, dy: 0)
        } else {
            return CGRect(
                x: 0, y: subviews[0].frame.maxY,
                width: bounds.width, height: dividerThickness
            ).insetBy(dx: 0, dy: -2)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let strip = primaryDividerStrip() else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let highlighted = strip.contains(localPoint)
        if highlighted != dividerHoverHighlighted {
            dividerHoverHighlighted = highlighted
            // Invalidate only the divider strip, not the whole split view
            setNeedsDisplay(strip)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if dividerHoverHighlighted {
            dividerHoverHighlighted = false
            if let strip = primaryDividerStrip() {
                setNeedsDisplay(strip)
            }
        }
    }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)
        guard dividerHoverHighlighted || isDraggingDivider else { return }
        // A rounded grip inset from the ends: softer while hovering, solid while dragging.
        let accent = AppSettings.shared.theme.accentEmphasis
        (isDraggingDivider ? accent : accent.withAlphaComponent(0.6)).setFill()
        let barThickness: CGFloat = isDraggingDivider ? 3 : 2
        let inset: CGFloat = 6
        let bar =
            isVertical
            ? CGRect(
                x: rect.midX - barThickness / 2, y: rect.minY + inset,
                width: barThickness, height: max(0, rect.height - inset * 2))
            : CGRect(
                x: rect.minX + inset, y: rect.midY - barThickness / 2,
                width: max(0, rect.width - inset * 2), height: barThickness)
        NSBezierPath(roundedRect: bar, xRadius: barThickness / 2, yRadius: barThickness / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, isPointOnPrimaryDivider(localPoint) {
            onDividerDoubleClick?()
            return
        }
        // Mouse-downs reaching the split view itself are on a divider; AppKit
        // runs the whole drag inside `super.mouseDown`.
        isDraggingDivider = true
        if let strip = primaryDividerStrip() { setNeedsDisplay(strip) }
        super.mouseDown(with: event)
        isDraggingDivider = false
        let localUp = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        dividerHoverHighlighted = primaryDividerStrip()?.contains(localUp) ?? false
        if let strip = primaryDividerStrip() { setNeedsDisplay(strip) }
        onDividerDragEnded?()
    }

    private func isPointOnPrimaryDivider(_ point: CGPoint) -> Bool {
        primaryDividerStrip()?.contains(point) ?? false
    }
}
