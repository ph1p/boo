import Cocoa

@MainActor protocol WorkspaceBarViewDelegate: AnyObject {
    func workspaceBar(_ bar: WorkspaceBarView, didSelectAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, didCloseAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, renameWorkspaceAt index: Int, to name: String)
    func workspaceBar(_ bar: WorkspaceBarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor)
    func workspaceBar(_ bar: WorkspaceBarView, setCustomColorForWorkspaceAt index: Int, color: NSColor)
    func workspaceBar(_ bar: WorkspaceBarView, togglePinForWorkspaceAt index: Int)
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceFrom source: Int, to destination: Int)
    func workspaceBarDidRequestNewWorkspace(_ bar: WorkspaceBarView)
}

class WorkspaceBarView: NSView {
    weak var delegate: WorkspaceBarViewDelegate?

    /// When true, draws workspace items stacked vertically.
    var isVertical: Bool = false
    /// When true, the vertical bar is on the right edge (separator on left).
    var isRightAligned: Bool = false

    static let workspaceIndexPBType = NSPasteboard.PasteboardType("com.boo.workspaceIndex")

    struct Item {
        let name: String
        let path: String
        var isPinned: Bool = false
        var color: WorkspaceColor = .none
        var hasCustomColor: Bool = false
        var resolvedColor: NSColor? = nil
    }

    private(set) var items: [Item] = []
    private(set) var selectedIndex: Int = -1

    private let barHeight: CGFloat = 28
    private var dragSourceIndex: Int?
    private var dropTargetIndex: Int?

    // Ghost drag state
    private var ghostWindow: NSWindow?
    private var isDragging: Bool = false

    // Hover state
    var hoveredIndex: Int = -1
    private var isPlusButtonHovered: Bool = false
    private var wsBarTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateWSBarTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cleanupDrag()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if isVertical {
            return NSSize(width: 40, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func setItems(_ items: [Item], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if isVertical {
            drawVertical(ctx)
        } else {
            drawHorizontal(ctx)
        }
    }

    // MARK: - Horizontal Drawing (top bar)

    private func drawHorizontal(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme

        // Background — deepest layer
        ctx.setFillColor(CGColor(red: 13 / 255, green: 13 / 255, blue: 15 / 255, alpha: 1))
        ctx.fill(bounds)

        // Bottom separator
        ctx.setFillColor(CGColor(red: 42 / 255, green: 42 / 255, blue: 47 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

        var x: CGFloat = 72  // Clear traffic lights

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            let isHovered = i == hoveredIndex
            let title = item.name as NSString
            let wsColor = item.resolvedColor

            let textColor: NSColor
            if let c = wsColor, isSelected {
                textColor = NSColor(
                    red: c.redComponent * 0.6 + 0.4, green: c.greenComponent * 0.6 + 0.4,
                    blue: c.blueComponent * 0.6 + 0.4, alpha: 1)
            } else if isSelected {
                textColor = NSColor(red: 228 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
            } else if let c = wsColor, isHovered {
                textColor = NSColor(
                    red: c.redComponent * 0.5 + 0.3, green: c.greenComponent * 0.5 + 0.3,
                    blue: c.blueComponent * 0.5 + 0.3, alpha: 1)
            } else if isHovered {
                textColor = NSColor(red: 160 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1)
            } else if let c = wsColor {
                textColor = NSColor(
                    red: c.redComponent * 0.5 + 0.2, green: c.greenComponent * 0.5 + 0.2,
                    blue: c.blueComponent * 0.5 + 0.2, alpha: 1)
            } else {
                textColor = NSColor(red: 86 / 255, green: 86 / 255, blue: 94 / 255, alpha: 1)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular),
                .foregroundColor: textColor
            ]
            let titleSize = title.size(withAttributes: attrs)
            let closeSpace: CGFloat = item.isPinned ? 0 : 16
            let pillWidth = titleSize.width + 32 + closeSpace
            let pillHeight: CGFloat = 20
            let pillY = (barHeight - pillHeight) / 2

            let pillRect = CGRect(x: x, y: pillY, width: pillWidth, height: pillHeight)

            if let c = wsColor {
                let alpha: CGFloat = isSelected ? 0.25 : (isHovered ? 0.18 : 0.12)
                ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if isSelected {
                ctx.setFillColor(CGColor(red: 35 / 255, green: 35 / 255, blue: 39 / 255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if isHovered {
                ctx.setFillColor(CGColor(red: 28 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1))
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }

            let textX = x + 14
            let textY = (barHeight - titleSize.height) / 2
            title.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            // Pin icon for pinned items
            if item.isPinned {
                drawPinIcon(ctx, at: NSPoint(x: pillRect.minX + 2, y: pillRect.minY + 1), color: textColor)
            }

            // Close button — on hover, not pinned
            if !item.isPinned && isHovered {
                let closeColor: NSColor =
                    wsColor?.withAlphaComponent(0.8)
                    ?? NSColor(red: 86 / 255, green: 86 / 255, blue: 94 / 255, alpha: 0.8)
                let closeBgColor: CGColor =
                    (wsColor?.withAlphaComponent(0.15)
                    ?? NSColor(red: 60 / 255, green: 60 / 255, blue: 68 / 255, alpha: 0.15)).cgColor
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: closeColor
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                let circleSize: CGFloat = 16
                let circleX = x + pillWidth - circleSize - 4
                let circleY = (barHeight - circleSize) / 2
                ctx.setFillColor(closeBgColor)
                ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
                closeStr.draw(
                    at: NSPoint(x: circleX + (circleSize - closeSize.width) / 2, y: (barHeight - closeSize.height) / 2),
                    withAttributes: closeAttrs
                )
            }

            x += pillWidth + 6
        }

        // Plus button
        let plusRect = horizontalPlusButtonRect(afterX: x)
        drawPlusButton(ctx, in: plusRect, isVertical: false)

        // Draw horizontal drop insertion indicator (vertical line between pills)
        if let dropIdx = dropTargetIndex {
            let indicatorX = horizontalDropIndicatorX(for: dropIdx)
            let pillHeight: CGFloat = 20
            let pillY = (barHeight - pillHeight) / 2
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: indicatorX - 1, y: pillY, width: 2, height: pillHeight))
        }
    }

    private func horizontalDropIndicatorX(for dropIdx: Int) -> CGFloat {
        var x: CGFloat = 72
        for i in 0..<min(dropIdx, items.count) {
            let isSelected = i == selectedIndex
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
            ]
            let titleWidth = (items[i].name as NSString).size(withAttributes: attrs).width
            let closeSpace: CGFloat = items[i].isPinned ? 0 : 16
            let pillWidth = titleWidth + 32 + closeSpace
            x += pillWidth + 6
        }
        return x - 3  // Center in the 6px gap
    }

    // MARK: - Vertical Drawing (left bar)

    private func drawVertical(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme

        // Background
        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(bounds)

        // Edge separator (right for left bar, left for right bar)
        ctx.setFillColor(theme.chromeBorder.cgColor)
        if isRightAligned {
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height))
        } else {
            ctx.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
        }

        let itemSize: CGFloat = 32
        let padding: CGFloat = 4
        var y: CGFloat = 8

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            let isHovered = i == hoveredIndex
            let wsColor = item.resolvedColor

            let pillRect = CGRect(x: padding, y: y, width: bounds.width - padding * 2, height: itemSize)

            if let c = wsColor {
                let alpha: CGFloat = isSelected ? 0.25 : (isHovered ? 0.18 : 0.12)
                ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if isSelected {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } else if isHovered {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
                ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }

            // Draw first character(s) as label
            let label = String(item.name.prefix(2)).uppercased()
            let textColor: NSColor
            if let c = wsColor, isSelected {
                textColor = NSColor(
                    red: c.redComponent * 0.6 + 0.4, green: c.greenComponent * 0.6 + 0.4,
                    blue: c.blueComponent * 0.6 + 0.4, alpha: 1)
            } else if isSelected {
                textColor = theme.chromeText
            } else if let c = wsColor {
                textColor = NSColor(
                    red: c.redComponent * 0.5 + 0.2, green: c.greenComponent * 0.5 + 0.2,
                    blue: c.blueComponent * 0.5 + 0.2, alpha: 1)
            } else {
                textColor = theme.chromeMuted
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
                .foregroundColor: textColor
            ]
            let labelSize = (label as NSString).size(withAttributes: attrs)
            let labelX = pillRect.midX - labelSize.width / 2
            let labelY = pillRect.midY - labelSize.height / 2
            (label as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)

            // Pin icon for pinned items
            if item.isPinned {
                drawPinIcon(ctx, at: NSPoint(x: pillRect.minX + 2, y: pillRect.minY + 2), color: textColor)
            }

            // Close button — on hover, not pinned
            if !item.isPinned && isHovered {
                let closeColor: NSColor = wsColor?.withAlphaComponent(0.8) ?? theme.chromeMuted.withAlphaComponent(0.8)
                let closeBgColor: NSColor =
                    wsColor?.withAlphaComponent(0.15) ?? theme.chromeMuted.withAlphaComponent(0.15)
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: closeColor
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                let circleSize: CGFloat = 16
                let circleX = pillRect.maxX - circleSize - 2
                let circleY = pillRect.midY - circleSize / 2
                ctx.setFillColor(closeBgColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
                closeStr.draw(
                    at: NSPoint(
                        x: circleX + (circleSize - closeSize.width) / 2,
                        y: circleY + (circleSize - closeSize.height) / 2),
                    withAttributes: closeAttrs
                )
            }

            y += itemSize + 4
        }

        // Plus button
        let plusRect = verticalPlusButtonRect(afterY: y)
        drawPlusButton(ctx, in: plusRect, isVertical: true)

        // Draw drop insertion indicator
        if let dropIdx = dropTargetIndex {
            let indicatorY: CGFloat = 8 + CGFloat(dropIdx) * (itemSize + 4) - 2
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: padding, y: indicatorY, width: bounds.width - padding * 2, height: 2))
        }
    }

    // MARK: - Pin Icon

    private func drawPinIcon(_ ctx: CGContext, at origin: NSPoint, color: NSColor) {
        let iconSize: CGFloat = 7
        let iconRect = NSRect(x: origin.x, y: origin.y, width: iconSize, height: iconSize)
        if let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
            let sized = pinImage.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? pinImage
            sized.isTemplate = true
            let tintColor = color.withAlphaComponent(0.5)

            let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                tintColor.set()
                sized.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSRect(origin: .zero, size: drawRect.size).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        } else {
            ctx.setFillColor(color.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: origin.x + 1, y: origin.y + 1, width: 5, height: 5))
        }
    }

    // MARK: - Plus Button

    private func horizontalPlusButtonRect(afterX x: CGFloat) -> CGRect {
        let size: CGFloat = 20
        let y = (barHeight - size) / 2
        return CGRect(x: x + 2, y: y, width: size, height: size)
    }

    private func verticalPlusButtonRect(afterY y: CGFloat) -> CGRect {
        let padding: CGFloat = 4
        let size: CGFloat = 32
        return CGRect(x: padding, y: y, width: bounds.width - padding * 2, height: size)
    }

    private func drawPlusButton(_ ctx: CGContext, in rect: CGRect, isVertical: Bool) {
        let theme = AppSettings.shared.theme

        if isPlusButtonHovered {
            let bg =
                isVertical
                ? theme.chromeMuted.withAlphaComponent(0.12).cgColor
                : CGColor(red: 28 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1)
            ctx.setFillColor(bg)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }

        let hoveredColor = NSColor(red: 160 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1)
        let defaultColor =
            isVertical
            ? theme.chromeMuted.withAlphaComponent(0.4)
            : NSColor(red: 86 / 255, green: 86 / 255, blue: 94 / 255, alpha: 0.7)
        let plusColor: NSColor = isPlusButtonHovered ? hoveredColor : defaultColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isVertical ? 14 : 11, weight: .light),
            .foregroundColor: plusColor
        ]
        let str = "+" as NSString
        let strSize = str.size(withAttributes: attrs)
        str.draw(
            at: NSPoint(x: rect.midX - strSize.width / 2, y: rect.midY - strSize.height / 2),
            withAttributes: attrs)
    }

    // MARK: - Click Handling

    override func mouseDown(with event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        let hitIdx = hitTestItemIndex(at: startPoint)

        // If click is not on any item, check for plus button or start a window drag
        guard let idx = hitIdx, idx >= 0, idx < items.count else {
            if isPlusButtonHit(at: startPoint) {
                delegate?.workspaceBarDidRequestNewWorkspace(self)
            } else {
                window?.performDrag(with: event)
            }
            return
        }

        // Double-click triggers rename
        if event.clickCount == 2 {
            showRenameAlert(at: idx)
            return
        }

        // Run a local tracking loop to prevent isMovableByWindowBackground
        // from hijacking the drag. We own the entire mouse sequence here.
        var didStartDrag = false

        guard let eventWindow = window else { return }
        while true {
            guard let nextEvent = eventWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            if nextEvent.type == .leftMouseUp {
                if !didStartDrag {
                    // Plain click — select or close
                    if isVertical {
                        handleVerticalClick(startPoint)
                    } else {
                        handleHorizontalClick(startPoint)
                    }
                } else {
                    executeDrop()
                }
                break
            }

            // leftMouseDragged
            if !didStartDrag {
                let dragPoint = convert(nextEvent.locationInWindow, from: nil)
                let distance = hypot(dragPoint.x - startPoint.x, dragPoint.y - startPoint.y)
                guard distance > 3 else { continue }
                guard !items[idx].isPinned else { break }
                guard items.filter({ !$0.isPinned }).count > 1 else { break }

                dragSourceIndex = idx
                isDragging = true
                didStartDrag = true
                createGhostWindow(for: idx, event: nextEvent)
            }

            handleDragMove(nextEvent)
        }

        if didStartDrag {
            cleanupDrag()
        }
    }

    // MARK: - Ghost Drag System

    private func createGhostWindow(for index: Int, event: NSEvent) {
        let item = items[index]
        let ghostWidth: CGFloat
        let ghostHeight: CGFloat
        let ghostView: NSView

        if isVertical {
            ghostWidth = 36
            ghostHeight = 36
            ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
            ghostView.wantsLayer = true
            ghostView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
            ghostView.layer?.cornerRadius = 6
            ghostView.layer?.borderColor = NSColor.separatorColor.cgColor
            ghostView.layer?.borderWidth = 1

            let label = NSTextField(labelWithString: String(item.name.prefix(2)).uppercased())
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor.labelColor
            label.alignment = .center
            label.frame = NSRect(x: 0, y: (ghostHeight - 16) / 2, width: ghostWidth, height: 16)
            ghostView.addSubview(label)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium)
            ]
            let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
            ghostWidth = min(titleWidth + 24, 140)
            ghostHeight = 22
            ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
            ghostView.wantsLayer = true
            ghostView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
            ghostView.layer?.cornerRadius = 6
            ghostView.layer?.borderColor = NSColor.separatorColor.cgColor
            ghostView.layer?.borderWidth = 1

            let label = NSTextField(labelWithString: item.name)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor.labelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 6, y: 2, width: ghostWidth - 12, height: ghostHeight - 4)
            ghostView.addSubview(label)
        }

        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        let win = NSWindow(
            contentRect: NSRect(
                x: screenPoint.x - ghostWidth / 2,
                y: screenPoint.y - ghostHeight / 2,
                width: ghostWidth, height: ghostHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = ghostView
        win.alphaValue = 0.85
        win.orderFront(nil)

        ghostWindow = win
    }

    private func handleDragMove(_ event: NSEvent) {
        // Move ghost window
        if let win = ghostWindow {
            let screenPoint: NSPoint
            if let eventWindow = event.window {
                screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
            } else {
                screenPoint = NSEvent.mouseLocation
            }
            let frame = win.frame
            win.setFrameOrigin(
                NSPoint(
                    x: screenPoint.x - frame.width / 2,
                    y: screenPoint.y - frame.height / 2))
        }

        // Update drop target
        updateDropTarget(event)
    }

    private func updateDropTarget(_ event: NSEvent) {
        guard let eventWindow = event.window ?? self.window else { return }
        let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        guard let myWindow = self.window else { return }
        let windowPoint = myWindow.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)

        let rawIdx: Int
        if isVertical {
            let itemSize: CGFloat = 32
            let spacing: CGFloat = 4
            let startY: CGFloat = 8
            var idx = Int((point.y - startY + spacing / 2) / (itemSize + spacing))
            idx = max(0, min(idx, items.count))
            rawIdx = idx
        } else {
            var x: CGFloat = 72
            var idx = items.count
            for (i, item) in items.enumerated() {
                let isSelected = i == selectedIndex
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
                ]
                let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
                let pillWidth = titleWidth + 36
                if point.x < x + pillWidth / 2 {
                    idx = i
                    break
                }
                x += pillWidth + 6
            }
            rawIdx = idx
        }

        let validIdx = validDropIndex(raw: rawIdx)
        if validIdx != dropTargetIndex {
            dropTargetIndex = validIdx
            needsDisplay = true
        }
    }

    private func validDropIndex(raw: Int) -> Int? {
        guard let src = dragSourceIndex else { return nil }
        // No-op moves
        if raw == src || raw == src + 1 { return nil }
        let lo = min(src, raw)
        let hi = max(src, raw)
        for i in lo..<hi where i != src {
            if items[i].isPinned { return nil }
        }
        return raw
    }

    private func executeDrop() {
        guard let dropIdx = dropTargetIndex, let sourceIdx = dragSourceIndex else { return }
        delegate?.workspaceBar(self, moveWorkspaceFrom: sourceIdx, to: dropIdx)
    }

    private func cleanupDrag() {
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
        isDragging = false
        dragSourceIndex = nil
        dropTargetIndex = nil
        needsDisplay = true
    }

    /// Returns screen-space rects for each workspace pill, used for tab-drag hover detection.
    func workspacePillScreenFrames() -> [(index: Int, screenFrame: NSRect)] {
        guard let window = window else { return [] }
        var result: [(Int, NSRect)] = []
        if isVertical {
            let itemSize: CGFloat = 32
            let padding: CGFloat = 4
            var y: CGFloat = 8
            for (i, _) in items.enumerated() {
                let localRect = NSRect(x: padding, y: y, width: bounds.width - padding * 2, height: itemSize)
                let windowRect = convert(localRect, to: nil)
                let screenRect = window.convertToScreen(windowRect)
                result.append((i, screenRect))
                y += itemSize + 4
            }
        } else {
            var x: CGFloat = 72
            for (i, item) in items.enumerated() {
                let isSelected = i == selectedIndex
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
                ]
                let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
                let closeSpace: CGFloat = item.isPinned ? 0 : 16
                let pillWidth = titleWidth + 32 + closeSpace
                let pillHeight: CGFloat = 20
                let pillY = (barHeight - pillHeight) / 2
                let localRect = NSRect(x: x, y: pillY, width: pillWidth, height: pillHeight)
                let windowRect = convert(localRect, to: nil)
                let screenRect = window.convertToScreen(windowRect)
                result.append((i, screenRect))
                x += pillWidth + 6
            }
        }
        return result
    }

    // MARK: - Right Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = hitTestItemIndex(at: point), idx >= 0, idx < items.count else { return }
        showContextMenu(at: idx, event: event)
    }

    private func showContextMenu(at index: Int, event: NSEvent) {
        let menu = NSMenu()
        let item = items[index]

        // Rename
        let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.tag = index
        menu.addItem(renameItem)

        menu.addItem(.separator())

        // Pin/Unpin
        let pinTitle = item.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextTogglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.tag = index
        menu.addItem(pinItem)

        menu.addItem(.separator())

        // Color submenu
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in WorkspaceColor.allCases {
            let ci = NSMenuItem(title: color.label, action: #selector(contextSetColor(_:)), keyEquivalent: "")
            ci.target = self
            ci.tag = index
            ci.representedObject = color
            if !item.hasCustomColor && color == item.color {
                ci.state = .on
            }
            colorMenu.addItem(ci)
        }
        colorMenu.addItem(.separator())
        let customItem = NSMenuItem(
            title: "Custom Color...", action: #selector(contextCustomColor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.tag = index
        if item.hasCustomColor {
            customItem.state = .on
        }
        colorMenu.addItem(customItem)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())

        // Close
        if !item.isPinned {
            let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = index
            menu.addItem(closeItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        showRenameAlert(at: sender.tag)
    }

    private func showRenameAlert(at index: Int) {
        guard index >= 0, index < items.count else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a new name for this workspace."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = items[index].name
        alert.accessoryView = input

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    self.delegate?.workspaceBar(self, renameWorkspaceAt: index, to: name)
                }
            }
        }
        alert.window.makeFirstResponder(input)
    }

    @objc private func contextTogglePin(_ sender: NSMenuItem) {
        delegate?.workspaceBar(self, togglePinForWorkspaceAt: sender.tag)
    }

    @objc private func contextSetColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? WorkspaceColor else { return }
        delegate?.workspaceBar(self, setCustomColorForWorkspaceAt: sender.tag, color: .clear)
        delegate?.workspaceBar(self, setColorForWorkspaceAt: sender.tag, color: color)
    }

    private var colorPickerIndex: Int = 0
    private var colorPickerActive: Bool = false

    @objc private func contextCustomColor(_ sender: NSMenuItem) {
        colorPickerIndex = sender.tag
        colorPickerActive = true
        let picker = NSColorPanel.shared
        picker.setTarget(self)
        picker.setAction(#selector(colorPickerChanged(_:)))
        picker.orderFront(nil)
    }

    @objc private func colorPickerChanged(_ sender: NSColorPanel) {
        delegate?.workspaceBar(self, setCustomColorForWorkspaceAt: colorPickerIndex, color: sender.color)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        delegate?.workspaceBar(self, didCloseAt: sender.tag)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, colorPickerActive {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            colorPickerActive = false
        }
    }

    // MARK: - Testing Hooks

    /// Directly invoke the double-click rename path. For tests only.
    func triggerDoubleClickForTesting(at index: Int) {
        showRenameAlert(at: index)
    }

    /// Directly invoke the single-click select/close path. For tests only.
    func triggerSingleClickForTesting(at index: Int) {
        guard index >= 0, index < items.count else { return }
        if isVertical {
            let itemSize: CGFloat = 32
            let y: CGFloat = 8 + CGFloat(index) * (itemSize + 4) + itemSize / 2
            let x: CGFloat = bounds.midX
            handleVerticalClick(NSPoint(x: x, y: y))
        } else {
            var x: CGFloat = 72
            for (i, item) in items.enumerated() {
                let isSelected = i == selectedIndex
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
                ]
                let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
                let closeSpace: CGFloat = item.isPinned ? 0 : 16
                let pillWidth = titleWidth + 32 + closeSpace
                if i == index {
                    // Click in the safe centre of the pill (away from the close button)
                    handleHorizontalClick(NSPoint(x: x + 14, y: bounds.midY))
                    return
                }
                x += pillWidth + 6
            }
        }
    }

    // MARK: - Hover Tracking

    private func updateWSBarTrackingArea() {
        if let existing = wsBarTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        wsBarTrackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWSBarTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = hitTestItemIndex(at: point) ?? -1
        let newPlusHover = isPlusButtonHit(at: point)
        if newHover != hoveredIndex || newPlusHover != isPlusButtonHovered {
            hoveredIndex = newHover
            isPlusButtonHovered = newPlusHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        var changed = false
        if hoveredIndex != -1 {
            hoveredIndex = -1
            changed = true
        }
        if isPlusButtonHovered {
            isPlusButtonHovered = false
            changed = true
        }
        if changed { needsDisplay = true }
    }

    // MARK: - Hit Testing

    private func hitTestItemIndex(at point: NSPoint) -> Int? {
        if isVertical {
            let itemSize: CGFloat = 32
            var y: CGFloat = 8
            for (i, _) in items.enumerated() {
                let rect = CGRect(x: 0, y: y, width: bounds.width, height: itemSize)
                if rect.contains(point) { return i }
                y += itemSize + 4
            }
        } else {
            var x: CGFloat = 72
            for (i, item) in items.enumerated() {
                let isSelected = i == selectedIndex
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
                ]
                let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
                let closeSpace: CGFloat = item.isPinned ? 0 : 16
                let pillWidth = titleWidth + 32 + closeSpace
                if point.x >= x && point.x < x + pillWidth { return i }
                x += pillWidth + 6
            }
        }
        return nil
    }

    private func isPlusButtonHit(at point: NSPoint) -> Bool {
        if isVertical {
            var y: CGFloat = 8
            for _ in items {
                y += 32 + 4
            }
            return verticalPlusButtonRect(afterY: y).contains(point)
        } else {
            var x: CGFloat = 72
            for (i, item) in items.enumerated() {
                let isSelected = i == selectedIndex
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
                ]
                let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
                let closeSpace: CGFloat = item.isPinned ? 0 : 16
                let pillWidth = titleWidth + 32 + closeSpace
                x += pillWidth + 6
            }
            return horizontalPlusButtonRect(afterX: x).contains(point)
        }
    }

    private func handleHorizontalClick(_ point: NSPoint) {
        var x: CGFloat = 72

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .medium : .regular)
            ]
            let titleWidth = (item.name as NSString).size(withAttributes: attrs).width
            let closeSpace: CGFloat = item.isPinned ? 0 : 16
            let pillWidth = titleWidth + 32 + closeSpace

            if point.x >= x && point.x < x + pillWidth {
                // Close button hit area — only when hovered
                let circleSize: CGFloat = 16
                let circleY = (barHeight - circleSize) / 2
                let closeRect = CGRect(
                    x: x + pillWidth - circleSize - 4, y: circleY, width: circleSize, height: circleSize)
                if !item.isPinned && i == hoveredIndex && closeRect.contains(point) {
                    delegate?.workspaceBar(self, didCloseAt: i)
                } else {
                    delegate?.workspaceBar(self, didSelectAt: i)
                }
                return
            }
            x += pillWidth + 6
        }
    }

    private func handleVerticalClick(_ point: NSPoint) {
        let itemSize: CGFloat = 32
        let padding: CGFloat = 4
        var y: CGFloat = 8

        for (i, item) in items.enumerated() {
            let pillRect = CGRect(x: padding, y: y, width: bounds.width - padding * 2, height: itemSize)
            if pillRect.contains(point) {
                // Close button hit area — only when hovered
                let circleSize: CGFloat = 16
                let closeRect = CGRect(
                    x: pillRect.maxX - circleSize - 2, y: pillRect.midY - circleSize / 2, width: circleSize,
                    height: circleSize)
                if !item.isPinned && i == hoveredIndex && closeRect.contains(point) {
                    delegate?.workspaceBar(self, didCloseAt: i)
                } else {
                    delegate?.workspaceBar(self, didSelectAt: i)
                }
                return
            }
            y += itemSize + 4
        }
    }
}
