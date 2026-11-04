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
    /// How far the grab strip reaches above the section border, and how far it
    /// overlaps into the header below it. The overlap band claims the top of
    /// the 26pt header for resizing (the view sits on top of the headers), so
    /// keep it small enough that collapse clicks and reorder drags still have
    /// most of the header to themselves.
    static let reachAbove: CGFloat = 6
    static let reachBelow: CGFloat = 4
    static var thickness: CGFloat { reachAbove + reachBelow }

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
        // Centre the bar on the section border, not on this view's own centre —
        // the grab strip reaches asymmetrically into the header below.
        let barH: CGFloat = 2
        let r = CGRect(x: 0, y: Self.reachAbove - barH / 2, width: bounds.width, height: barH)
        AppSettings.shared.theme.accentEmphasis.setFill()
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

    private var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// Splits a trailing "(N)" off a section name so the count renders as a badge.
    static func splitCount(_ name: String) -> (title: String, count: String?) {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return (name, nil) }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return (name, nil) }
        return (name[..<open].trimmingCharacters(in: .whitespaces), String(inner))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let padH: CGFloat = AppSettings.shared.sidebarDensity == .comfortable ? 12 : 8

        // Same surface as the panel: sections read as groups, not stacked bars.
        ctx.setFillColor(theme.sidebarBg.cgColor)
        ctx.fill(bounds)

        if isHovered {
            ctx.setFillColor(theme.sidebarRowHover.cgColor)
            // Same gap on every side, so the pill sits centered in the header.
            WorkspacePillStyle.fillRoundedRect(ctx, rect: bounds.insetBy(dx: 4, dy: 4))
        }

        let fg = isHovered ? theme.chromeText : theme.textSecondary
        // As wide as the down chevron: chevron, title and count badge sit 6pt apart.
        let chevronBox: CGFloat = 8
        let chevronName = isExpanded ? "chevron.down" : "chevron.right"
        if let chevronImage = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                .applying(.init(paletteColors: [theme.textTertiary]))
            let tinted = chevronImage.withSymbolConfiguration(config) ?? chevronImage
            let imgSize = tinted.size
            tinted.draw(
                in: NSRect(
                    x: padH + (chevronBox - imgSize.width) / 2, y: (bounds.height - imgSize.height) / 2,
                    width: imgSize.width, height: imgSize.height))
        }

        let (title, count) = Self.splitCount(name)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: fg]
        let titleStr = title as NSString
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        let titleX = padH + chevronBox + 6
        let maxTitleW = max(0, bounds.width - titleX - padH - 28)
        titleStr.draw(
            with: NSRect(
                x: titleX, y: (bounds.height - titleSize.height) / 2, width: maxTitleW,
                height: titleSize.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)

        guard let count else { return }
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.countFont, .foregroundColor: theme.textSecondary
        ]
        let countStr = count as NSString
        let countSize = countStr.size(withAttributes: countAttrs)
        let badgeH: CGFloat = 15
        let badgeW = max(badgeH, countSize.width + 10)
        let badge = CGRect(
            x: titleX + min(titleSize.width, maxTitleW) + 6, y: (bounds.height - badgeH) / 2,
            width: badgeW, height: badgeH)
        ctx.setFillColor(theme.hoverFill.cgColor)
        WorkspacePillStyle.fillRoundedRect(ctx, rect: badge, radius: badgeH / 2)
        countStr.draw(
            at: NSPoint(x: badge.midX - countSize.width / 2, y: badge.midY - countSize.height / 2),
            withAttributes: countAttrs)
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

// MARK: - Sidebar Icon Button

/// Small borderless glyph button for sidebar and drawer chrome. Unlike `IconButton` it
/// draws no hover fill; the whole frame is the hit area and `help` doubles as the
/// accessibility label.
struct SidebarIconButton: View {
    let systemName: String
    let help: String
    let tint: Color
    var enabled = true
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var frame: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .opacity(enabled ? 1 : 0.4)
                .frame(width: frame, height: frame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
