import Cocoa
import SwiftUI

// MARK: - Top-Aligned Scroll View

/// NSScrollView subclass that pins content to the top instead of centering
/// when the document is shorter than the visible area.
class TopAlignedScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        contentView = clip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }
}

// MARK: - Drag Handle View

/// View placed at the border between two expanded sections.
/// Handles mouse drag to resize the sections above and below.
/// Shows an accent-colored bar on hover/drag, like VS Code section resize handles.
class SidebarDragHandleView: NSView {
    var aboveIndex: Int = 0
    var belowIndex: Int = 0
    weak var panelView: SidebarPanelView?

    private var dragStartY: CGFloat = 0
    private var startHeights: (CGFloat, CGFloat) = (0, 0)
    private var isActive = false  // true while hovered or dragging

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isActive = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isActive = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let barH: CGFloat = 2
        let r = CGRect(x: 0, y: (bounds.height - barH) / 2, width: bounds.width, height: barH)
        AppSettings.shared.theme.accentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: r).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = panelView else { return }
        let globalPoint = panel.convert(event.locationInWindow, from: nil)
        dragStartY = globalPoint.y
        startHeights = (
            panel.sectionStates[aboveIndex].contentHeight,
            panel.sectionStates[belowIndex].contentHeight
        )
        NSCursor.resizeUpDown.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = panelView else { return }
        let point = panel.convert(event.locationInWindow, from: nil)
        let delta = point.y - dragStartY
        panel.handleDrag(
            aboveIndex: aboveIndex, belowIndex: belowIndex, delta: delta,
            startHeights: startHeights)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        // Notify panel that drag ended — triggers persistence of heights to Settings
        panelView?.handleDragEnded()
    }
}

// MARK: - Section Header (AppKit)

class SidebarSectionHeaderView: NSView {
    var sectionID: String
    private var name: String
    private var icon: String
    private var isExpanded: Bool
    var onToggle: ((String) -> Void)?
    /// Called when the user begins dragging this header to reorder sections.
    var onBeginDrag: ((String, NSEvent) -> Void)?
    /// Called when the user right-clicks and chooses "Hide Section".
    /// The closure receives the sectionID. Will be nil when hiding is not allowed
    /// (i.e. this is the last remaining visible section).
    var onHideSection: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(sectionID: String, name: String, icon: String, isExpanded: Bool) {
        self.sectionID = sectionID
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(name: String, icon: String, isExpanded: Bool) {
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity
        let padH: CGFloat = density == .comfortable ? 12 : 8

        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(bounds)

        let chevronName = isExpanded ? "chevron.down" : "chevron.right"
        let chevronBox: CGFloat = 12
        if let chevronImage = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(.init(paletteColors: [theme.chromeMuted]))
            let tinted = chevronImage.withSymbolConfiguration(config) ?? chevronImage
            let imgSize = tinted.size
            let chevronX = padH + (chevronBox - imgSize.width) / 2
            let chevronY = (bounds.height - imgSize.height) / 2
            tinted.draw(
                in: NSRect(x: chevronX, y: chevronY, width: imgSize.width, height: imgSize.height))
        }

        let titleStr = name.uppercased() as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: theme.chromeMuted
        ]
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        let titleY = (bounds.height - titleSize.height) / 2
        titleStr.draw(
            at: NSPoint(x: padH + chevronBox + 5, y: titleY), withAttributes: titleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        // Track mouse to distinguish click from drag
        var didDrag = false
        let startPoint = convert(event.locationInWindow, from: nil)

        var nextEvent = event
        while nextEvent.type != .leftMouseUp {
            guard let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }
            nextEvent = e
            if e.type == .leftMouseDragged {
                let current = convert(e.locationInWindow, from: nil)
                let dist = hypot(current.x - startPoint.x, current.y - startPoint.y)
                if dist > 4 {
                    didDrag = true
                    onBeginDrag?(sectionID, event)
                    break
                }
            }
        }

        if !didDrag {
            onToggle?(sectionID)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if let onHide = onHideSection {
            let item = NSMenuItem(
                title: "Hide \"\(name)\"",
                action: #selector(hideSectionFromMenu),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            _ = onHide  // captured via @objc method below
        } else {
            let item = NSMenuItem(title: "Cannot hide last section", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func hideSectionFromMenu() {
        onHideSection?(sectionID)
    }
}

// MARK: - SwiftUI Bridge

struct SidebarPluginStackView: NSViewRepresentable {
    let sections: [SidebarSection]
    let expandedIDs: Set<String>
    let onToggleExpand: (String) -> Void

    func makeNSView(context: Context) -> SidebarPanelView {
        let view = SidebarPanelView(frame: .zero)
        view.onToggleExpand = onToggleExpand
        view.updateSections(sections, expandedIDs: expandedIDs)
        return view
    }

    func updateNSView(_ nsView: SidebarPanelView, context: Context) {
        nsView.onToggleExpand = onToggleExpand
        nsView.updateSections(sections, expandedIDs: expandedIDs)
    }
}
