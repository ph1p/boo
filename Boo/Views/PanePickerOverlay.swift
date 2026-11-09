import Cocoa

/// Labels every pane of the workspace with a key; typing it focuses that
/// pane, or swaps it with the active one in swap mode (Tab toggles). Esc or
/// a click cancels. Labels follow the split tree's order, as ⌃⌘1-9 do.
final class PanePickerOverlay: NSView {
    static let labels = Array("123456789abcdefghijklmnopqrstuvwxyz")

    struct Target {
        let paneID: UUID
        let frame: NSRect
        let isActive: Bool
    }

    private let targets: [Target]
    private let onPick: (UUID, _ swap: Bool) -> Void
    private var swapMode = false
    private weak var previousResponder: NSResponder?

    init(frame: NSRect, targets: [Target], onPick: @escaping (UUID, Bool) -> Void) {
        self.targets = Array(targets.prefix(Self.labels.count))
        self.onPick = onPick
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane picker")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func show(in window: NSWindow) {
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
    }

    /// The pane a typed key names; nil for anything else.
    static func paneIndex(for characters: String) -> Int? {
        guard characters.count == 1, let char = characters.lowercased().first else { return nil }
        return labels.firstIndex(of: char)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            close(restoreFocus: true)
            return
        case 48:  // Tab
            swapMode.toggle()
            needsDisplay = true
            return
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers, let index = Self.paneIndex(for: chars),
            targets.indices.contains(index)
        else {
            NSSound.beep()
            return
        }
        let target = targets[index]
        let swap = swapMode
        close(restoreFocus: false)
        onPick(target.paneID, swap)
    }

    // Swallow menu shortcuts while picking, except the one that opened it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if event.modifierFlags.contains(.command) {
            close(restoreFocus: true)
            return false
        }
        keyDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        close(restoreFocus: true)
    }

    override func resignFirstResponder() -> Bool {
        // Focus moved elsewhere (a click into another view, a window switch).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.superview != nil, self.window?.firstResponder !== self else { return }
            self.removeFromSuperview()
        }
        return true
    }

    private func close(restoreFocus: Bool) {
        let window = self.window
        let previous = previousResponder
        removeFromSuperview()
        if restoreFocus, let previous { window?.makeFirstResponder(previous) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        let accent = swapMode ? NSColor.systemOrange : NSColor.controlAccentColor
        for (index, target) in targets.enumerated() {
            let frame = target.frame.insetBy(dx: 2, dy: 2)
            accent.withAlphaComponent(target.isActive ? 0.9 : 0.5).setStroke()
            let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            outline.lineWidth = target.isActive ? 3 : 2
            outline.stroke()

            let label = String(Self.labels[index]).uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attributes)
            let badge = NSRect(
                x: frame.midX - (size.width + 28) / 2, y: frame.midY - (size.height + 16) / 2,
                width: size.width + 28, height: size.height + 16)
            accent.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
            label.draw(
                at: NSPoint(x: badge.minX + 14, y: badge.minY + 8), withAttributes: attributes)
        }
        let hint =
            (swapMode ? "Swap with active pane" : "Jump to pane")
            + " · Tab: \(swapMode ? "jump" : "swap") · Esc: cancel"
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
        ]
        let hintSize = (hint as NSString).size(withAttributes: hintAttributes)
        let hintRect = NSRect(
            x: bounds.midX - (hintSize.width + 20) / 2, y: bounds.minY + 12, width: hintSize.width + 20,
            height: hintSize.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: hintRect, xRadius: 6, yRadius: 6).fill()
        (hint as NSString).draw(
            at: NSPoint(x: hintRect.minX + 10, y: hintRect.minY + 4), withAttributes: hintAttributes)
    }
}

extension MainWindowController {
    func showPanePicker() {
        guard let ws = activeWorkspace, let window, let container = splitContainer else { return }
        // Every pane needs a frame to carry a label.
        if ws.zoomedPaneID != nil { setZoomedPane(nil, in: ws) }
        let ids = ws.splitTree.leafIDs
        guard ids.count > 1 else { return }
        container.layoutSubtreeIfNeeded()
        let targets = ids.compactMap { id -> PanePickerOverlay.Target? in
            guard let pv = paneViews[id], pv.window != nil else { return nil }
            return .init(paneID: id, frame: pv.convert(pv.bounds, to: container), isActive: id == ws.activePaneID)
        }
        let overlay = PanePickerOverlay(
            frame: container.bounds, targets: targets,
            onPick: { [weak self, weak ws] paneID, swap in
                guard let self, let ws else { return }
                if swap, paneID != ws.activePaneID {
                    let active = ws.activePaneID
                    self.swapPanes(active, paneID, in: ws)
                    self.focusPane(active, in: ws)
                } else {
                    self.focusPane(paneID, in: ws)
                }
            })
        container.addSubview(overlay)
        overlay.show(in: window)
    }
}
