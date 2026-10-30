import Cocoa

/// Reorder animation for the custom-drawn tab bar: after a move, each pill
/// starts at its old slot and slides into the new one. The offsets live in a
/// map keyed by tab ID that the draw code adds to every pill's position.
struct TabSlide {
    static let duration: CFTimeInterval = 0.18

    /// Old slot origin minus new slot origin, per tab that moved.
    let from: [UUID: CGPoint]
    let start: CFTimeInterval

    /// Remaining offset of a tab at `now`, easing out to zero.
    func offset(for tabID: UUID, at now: CFTimeInterval) -> CGPoint {
        guard let delta = from[tabID] else { return .zero }
        let remaining = 1 - Self.easeOut(Self.progress(start: start, now: now))
        return CGPoint(x: delta.x * remaining, y: delta.y * remaining)
    }

    func isFinished(at now: CFTimeInterval) -> Bool {
        Self.progress(start: start, now: now) >= 1
    }

    static func progress(start: CFTimeInterval, now: CFTimeInterval) -> CGFloat {
        if now >= start + duration { return 1 }
        return CGFloat(max((now - start) / duration, 0))
    }

    /// Cubic ease-out.
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    /// Per-tab offsets between two slot snapshots; tabs that stayed put are left out.
    static func offsets(old: [UUID: CGPoint], new: [UUID: CGPoint]) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        for (id, newOrigin) in new {
            guard let oldOrigin = old[id], oldOrigin != newOrigin else { continue }
            result[id] = CGPoint(x: oldOrigin.x - newOrigin.x, y: oldOrigin.y - newOrigin.y)
        }
        return result
    }
}

extension PaneView {
    /// Move a tab and slide the pills from their old slots into the new ones.
    func moveTabAnimated(from source: Int, to destination: Int) {
        let old = tabSlotOrigins()
        pane.moveTab(from: source, to: destination)
        let offsets = TabSlide.offsets(old: old, new: tabSlotOrigins())
        needsDisplay = true
        guard !offsets.isEmpty, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        tabSlide = TabSlide(from: offsets, start: CACurrentMediaTime())
        guard tabSlideLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepTabSlide))
        link.add(to: .main, forMode: .common)
        tabSlideLink = link
    }

    func tabSlideOffset(for tabID: UUID) -> CGPoint {
        tabSlide?.offset(for: tabID, at: CACurrentMediaTime()) ?? .zero
    }

    @objc private func stepTabSlide(_ link: CADisplayLink) {
        needsDisplay = true
        if tabSlide?.isFinished(at: CACurrentMediaTime()) ?? true {
            tabSlide = nil
            link.invalidate()
            tabSlideLink = nil
        }
    }

    private func tabSlotOrigins() -> [UUID: CGPoint] {
        var origins: [UUID: CGPoint] = [:]
        for (i, tab) in pane.tabs.enumerated() {
            if let slot = tabSlotRect(at: i) { origins[tab.id] = slot.origin }
        }
        return origins
    }
}
