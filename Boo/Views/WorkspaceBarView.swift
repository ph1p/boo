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
    /// Always true in the app — the bar only ever renders as a side strip, with
    /// top-bar workspaces drawn by `ToolbarView` instead. Kept as a property because
    /// the setup path sets it explicitly and `hitTest`/`draw` bail out until it is.
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
        MainActor.assumeIsolated { cleanupDrag() }
    }

    /// Y of the first pill in the vertical bar. The strip is already inset from
    /// the window by the island gap, so it starts flush with the content beside
    /// it. Shared by draw, hit-test and drop-index so they can't drift apart.
    static let verticalTopInset: CGFloat = 0

    /// Horizontal inset of a pill inside the vertical strip.
    static let verticalPadding: CGFloat = 4

    /// Width the strip *claims* in the window layout — what the panes sit clear of.
    /// One number, shared with the layout code in `MainWindowController`.
    static let verticalWidth: CGFloat = 40

    /// Extra width the view's frame carries beyond `verticalWidth`, used only as
    /// scratch space for the expanded hover pill. The panes are laid out against
    /// `verticalWidth`, so this band overlaps them — the view sits above the split
    /// view and `hitTest` lets anything not on the expanded pill fall through.
    static let verticalHoverOverhang: CGFloat = 140

    /// Total frame width of the view: the visible strip plus the overhang the
    /// expanded hover pill floats into.
    static let verticalFrameWidth: CGFloat = verticalWidth + verticalHoverOverhang

    /// X where the visible strip starts inside the frame. On a right-side bar the
    /// overhang is on the left, so the strip is pushed to the far edge.
    var verticalStripX: CGFloat {
        isRightAligned ? bounds.width - Self.verticalWidth : 0
    }

    /// Width of a resting pill — the strip minus its padding.
    var verticalPillWidth: CGFloat {
        Self.verticalWidth - Self.verticalPadding * 2
    }

    /// X of a resting pill in the strip.
    var verticalPillX: CGFloat { verticalStripX + Self.verticalPadding }

    /// Narrowest the expanded hover pill gets. Short names still read as a pill
    /// rather than collapsing to the width of their own text.
    static let verticalHoveredPillMinWidth: CGFloat = 110

    /// Widest it may grow, so a long workspace name truncates instead of running
    /// most of the way across the panes.
    static let verticalHoveredPillMaxWidth: CGFloat =
        verticalWidth + verticalHoverOverhang - verticalPadding

    /// Horizontal padding inside the expanded pill, either side of its contents.
    static let verticalHoveredPillPadding: CGFloat = 10

    /// Font the expanded pill's name is drawn in. Shared by the measure and the draw
    /// so the pill can't be sized against different metrics than it paints with.
    static func verticalHoveredPillFont(selected: Bool) -> NSFont {
        NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular)
    }

    /// Frame of the expanded pill for the hovered workspace: same top and height as
    /// its resting pill, grown inward over the panes. Width hugs the name — clamped
    /// to a minimum so short names still look like pills, and to a maximum so long
    /// ones truncate rather than sprawl.
    func verticalHoveredPillRect(at index: Int) -> CGRect {
        let rest = verticalItemRect(at: index)
        guard index >= 0, index < items.count else { return rest }
        let item = items[index]

        let font = Self.verticalHoveredPillFont(selected: index == selectedIndex)
        let textW = (item.name as NSString).size(withAttributes: [.font: font]).width
        // Padding either side, plus room for the close button (pinned items show a
        // pin inside the pill instead, which needs no reserved column).
        let trailing =
            item.isPinned ? 0 : WorkspacePillStyle.closeButtonSize + Self.verticalHoveredPillPadding
        let w = min(
            Self.verticalHoveredPillMaxWidth,
            max(
                Self.verticalHoveredPillMinWidth,
                ceil(textW) + Self.verticalHoveredPillPadding * 2 + trailing))

        // Grows toward the panes: rightward on a left bar, leftward on a right bar,
        // so it never runs off the window edge.
        let x = isRightAligned ? rest.maxX - w : rest.minX
        return CGRect(x: x, y: rest.minY, width: w, height: rest.height)
    }

    /// Height of one pill in the vertical strip.
    static let verticalItemSize: CGFloat = 32

    /// Gap between stacked pills.
    static let verticalItemGap: CGFloat = 4

    /// Depth of the scroll fade at each end of the pill stack. Deep enough that a
    /// clipped pill has fully dissolved before it reaches the edge, matching the
    /// top bar's left/right fades.
    static let verticalFadeHeight: CGFloat = 24

    /// Fonts used per pill on every draw pass — built once rather than per pill.
    nonisolated(unsafe) static let plusGlyphFont = NSFont.systemFont(ofSize: 17, weight: .light)
    nonisolated(unsafe) static let pillLabelSelected = NSFont.systemFont(
        ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let pillLabelRegular = NSFont.systemFont(
        ofSize: 11, weight: .regular)

    /// `WorkspacePillStyle.fillRoundedRect` at this view's control radius, so the
    /// per-pill draw sites read as one call rather than a three-line path recipe.
    private func fillRoundedRect(
        _ ctx: CGContext, rect: CGRect, radius: CGFloat = IslandMetrics.controlRadius
    ) {
        WorkspacePillStyle.fillRoundedRect(ctx, rect: rect, radius: radius)
    }

    /// How far the vertical strip is scrolled, in points. The mirror of the top
    /// bar's `workspaceScrollOffset`, only along Y.
    var verticalScrollOffset: CGFloat = 0 {
        didSet {
            if verticalScrollOffset != oldValue { needsDisplay = true }
        }
    }

    /// Total height of the pill stack, before clamping. The `+` is pinned to the
    /// bottom of the strip rather than riding at the end of the stack, so it is not
    /// counted here.
    var verticalContentHeight: CGFloat {
        let step = Self.verticalItemSize + Self.verticalItemGap
        return Self.verticalTopInset + CGFloat(items.count) * step
    }

    /// Height the scrolling pill stack gets: the strip minus the band reserved for
    /// the pinned `+`, so pills scroll *behind* it instead of off the bottom.
    var verticalScrollViewportHeight: CGFloat {
        max(0, bounds.height - Self.verticalItemSize - Self.verticalItemGap)
    }

    /// Furthest the strip can scroll: zero when everything already fits.
    var maxVerticalScrollOffset: CGFloat {
        max(0, verticalContentHeight - verticalScrollViewportHeight)
    }

    /// Frame of the pill at `index`, in view coordinates, with the scroll offset
    /// applied. The single source every draw and hit-test path walks, so the drawn
    /// pill and its click target can't drift apart.
    func verticalItemRect(at index: Int) -> CGRect {
        let step = Self.verticalItemSize + Self.verticalItemGap
        let y = Self.verticalTopInset + CGFloat(index) * step - verticalScrollOffset
        return CGRect(
            x: verticalPillX, y: y, width: verticalPillWidth, height: Self.verticalItemSize)
    }

    /// Frame of the `+`, pinned to the bottom of the strip. It used to ride at the
    /// end of the stack, which scrolled it out of reach once the workspaces
    /// overflowed. Same footprint as a pill.
    var verticalPlusRect: CGRect {
        CGRect(
            x: verticalPillX, y: bounds.height - Self.verticalItemSize,
            width: verticalPillWidth, height: Self.verticalItemSize)
    }

    /// Only the visible strip — and the expanded hover pill — take mouse events. The
    /// rest of the frame is transparent scratch space lying over the panes, so it
    /// must let clicks through or it would swallow half a terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isVertical else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let strip = CGRect(
            x: verticalStripX, y: 0, width: Self.verticalWidth, height: bounds.height)
        if strip.contains(local) { return self }
        if hoveredIndex >= 0, hoveredIndex < items.count,
            verticalHoveredPillRect(at: hoveredIndex).contains(local)
        {
            return self
        }
        return nil
    }

    /// Test seam for `clampVerticalScroll` / `verticalCloseButtonRect`, which are
    /// private because nothing in the app calls them from outside.
    func clampVerticalScrollForTesting() { clampVerticalScroll() }
    func verticalCloseButtonRectForTesting(in pillRect: CGRect) -> CGRect {
        verticalCloseButtonRect(in: pillRect)
    }

    private func clampVerticalScroll() {
        verticalScrollOffset = min(max(0, verticalScrollOffset), maxVerticalScrollOffset)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if isVertical {
            return NSSize(width: Self.verticalFrameWidth, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    func setItems(_ items: [Item], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        clampVerticalScroll()
        scrollToSelectedVertical()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // This view is only ever used as a vertical (left/right) bar; the top bar
        // is drawn by ToolbarView. Click/hit-test still support the horizontal
        // layout for tests, but there is no horizontal draw path.
        guard isVertical, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawVertical(ctx)
    }

    // MARK: - Vertical Drawing (left bar)

    private func drawVertical(_ ctx: CGContext) {
        let theme = AppSettings.shared.theme

        // No fill and no edge stroke: like the toolbar and status bar, this is a
        // bare strip over the window backdrop. Only the pills carry chrome.

        // Resolved once, not per pill: `IslandMetrics.borderColor` re-reads the
        // theme and re-runs the chrome-border blend on every access.
        let islandBorder = IslandMetrics.borderColor

        // Clip the scrolling stack to its viewport so a pill straddling the bottom
        // edge is cut off cleanly instead of bleeding into the pinned `+`.
        ctx.saveGState()
        ctx.clip(
            to: CGRect(x: 0, y: 0, width: bounds.width, height: verticalScrollViewportHeight))

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            // The hovered workspace is painted separately, expanded, after this loop
            // so it floats above its neighbours instead of being overdrawn by them.
            if i == hoveredIndex { continue }
            let isHovered = false
            let wsColor = item.resolvedColor

            let pillRect = verticalItemRect(at: i)
            // Skip pills scrolled out of the stack's viewport — nothing to paint, and
            // it keeps the cost flat as the workspace count grows.
            if pillRect.maxY < 0 || pillRect.minY > verticalScrollViewportHeight { continue }

            // Identical fill + accent border as the top bar, via the shared
            // WorkspacePillStyle. Only the square geometry differs here.
            WorkspacePillStyle.fill(
                ctx, rect: pillRect, active: isSelected, hovered: isHovered,
                wsColor: wsColor, neutral: theme.chromeMuted)
            if isSelected {
                WorkspacePillStyle.strokeBorder(ctx, rect: pillRect, accent: theme.accentColor)
            } else {
                // Every pill is an island, so every pill carries the island hairline —
                // tinted by the workspace's own colour when it has one.
                WorkspacePillStyle.strokeIslandBorder(
                    ctx, rect: pillRect, wsColor: wsColor, neutral: islandBorder)
            }

            // Draw first character(s) as label. Same text-color model as the top bar.
            let label = String(item.name.prefix(2)).uppercased()
            let textColor = WorkspacePillStyle.labelColor(
                wsColor: wsColor, active: isSelected, text: theme.chromeText,
                muted: theme.chromeMuted)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isSelected ? Self.pillLabelSelected : Self.pillLabelRegular,
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
        }

        ctx.restoreGState()

        // Scroll fades, mirroring the top bar's left/right edges along Y: a pill
        // clipped at the viewport boundary dissolves into the backdrop instead of
        // ending on a hard cut.
        if verticalScrollOffset > 0 {
            drawVerticalFadeEdge(ctx, at: 0, height: Self.verticalFadeHeight, topDown: true)
        }
        if verticalScrollOffset < maxVerticalScrollOffset {
            drawVerticalFadeEdge(
                ctx, at: verticalScrollViewportHeight - Self.verticalFadeHeight,
                height: Self.verticalFadeHeight, topDown: false)
        }

        // The hovered workspace, expanded over the panes: full name plus the close
        // button, neither of which fits in the two-letter resting pill. Outside the
        // stack's clip — it deliberately floats past the strip.
        drawExpandedHoverPill(ctx, theme: theme)

        // Plus button — pinned to the bottom, painted last so a pill scrolled to the
        // very end passes behind it.
        drawPlusButton(ctx, in: verticalPlusRect, theme: theme)

        // Draw drop insertion indicator
        if let dropIdx = dropTargetIndex {
            let indicatorY = verticalItemRect(at: dropIdx).minY - 2
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: verticalPillX, y: indicatorY, width: verticalPillWidth, height: 2))

        }
    }

    /// Dissolve the clipped end of the pill stack into the window backdrop, the
    /// vertical twin of `ToolbarView.drawFadeEdge`. `topDown` means opaque at `y`
    /// fading away downward — the view is flipped, so that is the *top* edge.
    ///
    /// Only the visible strip is faded: the frame's overhang is transparent scratch
    /// space over the panes, and painting backdrop into it would show as a band.
    private func drawVerticalFadeEdge(
        _ ctx: CGContext, at y: CGFloat, height: CGFloat, topDown: Bool
    ) {
        let bgColor = AppSettings.shared.theme.windowBackdrop.cgColor
        let components = bgColor.components ?? [0, 0, 0, 1]
        let r = !components.isEmpty ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        let colors: [CGFloat] =
            topDown
            ? [r, g, b, 1.0, r, g, b, 0.0]
            : [r, g, b, 0.0, r, g, b, 1.0]
        guard
            let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceRGB(), colorComponents: colors,
                locations: nil, count: 2)
        else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: verticalStripX, y: y, width: Self.verticalWidth, height: height))
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: y), end: CGPoint(x: 0, y: y + height), options: [])
        ctx.restoreGState()
    }

    /// Paint the hovered workspace as a wide pill floating over the panes. Drawn
    /// after the resting stack so it sits on top of its neighbours, with a shadow to
    /// read as a layer above the content rather than a hole punched in the strip.
    private func drawExpandedHoverPill(_ ctx: CGContext, theme: TerminalTheme) {
        guard hoveredIndex >= 0, hoveredIndex < items.count else { return }
        let i = hoveredIndex
        let item = items[i]
        let rest = verticalItemRect(at: i)
        // A pill scrolled out of the stack has no business floating over the panes.
        if rest.maxY < 0 || rest.minY > verticalScrollViewportHeight { return }

        let rect = verticalHoveredPillRect(at: i)
        let isSelected = i == selectedIndex
        let wsColor = item.resolvedColor

        // Opaque backdrop under the pill fill: the fill itself is translucent, and
        // terminal text showing through a floating control reads as a glitch.
        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: WorkspacePillStyle.cornerRadius,
                cornerHeight: WorkspacePillStyle.cornerRadius, transform: nil))
        ctx.fillPath()

        WorkspacePillStyle.fill(
            ctx, rect: rect, active: isSelected, hovered: true, wsColor: wsColor,
            neutral: theme.chromeMuted)
        // A hairline all the way round: with the shadow gone this is what separates
        // the floating pill from the terminal content behind it. The active
        // workspace keeps its accent stroke instead.
        if isSelected {
            WorkspacePillStyle.strokeBorder(ctx, rect: rect, accent: theme.accentColor)
        } else {
            WorkspacePillStyle.strokeIslandBorder(
                ctx, rect: rect, wsColor: wsColor, neutral: IslandMetrics.borderColor)
        }

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
            textColor = theme.chromeText
        }

        let closeSize = WorkspacePillStyle.closeButtonSize
        let sidePad = Self.verticalHoveredPillPadding
        // Text runs from the strip side toward the panes, stopping short of the close
        // button so a long workspace name truncates instead of colliding with it.
        let textInset = item.isPinned ? sidePad : sidePad + closeSize
        let textX = isRightAligned ? rect.minX + textInset : rect.minX + sidePad
        let textW = rect.width - sidePad - textInset

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.verticalHoveredPillFont(selected: isSelected),
            .foregroundColor: textColor,
            .paragraphStyle: para
        ]
        let name = item.name as NSString
        let textH = name.size(withAttributes: attrs).height
        name.draw(
            in: CGRect(x: textX, y: rect.midY - textH / 2, width: max(0, textW), height: textH),
            withAttributes: attrs)

        if item.isPinned {
            drawPinIcon(
                ctx, at: NSPoint(x: rect.minX + 3, y: rect.minY + 3), color: textColor)
        } else {
            WorkspacePillStyle.drawCloseButton(
                ctx, in: verticalCloseButtonRect(in: rect),
                tint: wsColor ?? theme.chromeMuted, bg: theme.chromeBg)
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

    /// Hover close-button rect for a vertical pill: top corner away from the bar's
    /// edge — upper-right on the left bar, upper-left on the right bar. (Flipped view,
    /// so the top is `minY`.)
    private func verticalCloseButtonRect(in pillRect: CGRect) -> CGRect {
        let circleSize = WorkspacePillStyle.closeButtonSize
        // Lives inside the *expanded* hover pill, at the end facing the panes. The
        // resting pill is only as wide as its two-letter label, so there is nowhere
        // to put it there without covering the text.
        let inset = Self.verticalHoveredPillPadding
        let circleX =
            isRightAligned ? pillRect.minX + inset : pillRect.maxX - circleSize - inset
        return CGRect(
            x: circleX, y: pillRect.midY - circleSize / 2, width: circleSize, height: circleSize)
    }

    private func drawPlusButton(_ ctx: CGContext, in rect: CGRect, theme: TerminalTheme) {
        if isPlusButtonHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.12).cgColor)
            fillRoundedRect(ctx, rect: rect)
        }

        let plusColor =
            isPlusButtonHovered
            ? NSColor(red: 160 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1)
            : theme.chromeMuted.withAlphaComponent(0.4)
        let attrs: [NSAttributedString.Key: Any] = [
            // The `+` sits in a full pill-sized footprint, so it carries a heavier
            // glyph than a plain toolbar button would.
            .font: Self.plusGlyphFont,
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
                    handleVerticalClick(startPoint)
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
        let ghostSize: CGFloat = 36
        let ghostWidth = ghostSize
        let ghostHeight = ghostSize
        let ghostView = NSView(frame: NSRect(x: 0, y: 0, width: ghostWidth, height: ghostHeight))
        // Same rounding treatment as every other island, via the shared helper so the
        // ghost picks up `cornerCurve = .continuous` instead of a bare corner radius.
        IslandMetrics.round(ghostView, radius: IslandMetrics.innerRadius)
        ghostView.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor

        let label = NSTextField(labelWithString: String(item.name.prefix(2)).uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (ghostHeight - 16) / 2, width: ghostWidth, height: 16)
        ghostView.addSubview(label)

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

        let step = Self.verticalItemSize + Self.verticalItemGap
        // Point is in view space, so undo the scroll before mapping to an index.
        let contentY = point.y + verticalScrollOffset - Self.verticalTopInset
        let rawIdx = max(0, min(Int((contentY + Self.verticalItemGap / 2) / step), items.count))

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
        for (i, _) in items.enumerated() {
            let windowRect = convert(verticalItemRect(at: i), to: nil)
            result.append((i, window.convertToScreen(windowRect)))
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
        handleVerticalClick(
            CGPoint(x: verticalItemRect(at: index).midX, y: verticalItemRect(at: index).midY))
    }

    // MARK: - Hover Tracking

    private func updateWSBarTrackingArea() {
        guard wsBarTrackingArea?.rect != bounds else { return }
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
        // A taller strip can fit more pills, so a previously valid offset may now
        // scroll past the end.
        clampVerticalScroll()
        updateWSBarTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        updateVerticalHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Recompute what the cursor is over. Called on mouse move and after a scroll,
    /// since scrolling moves the pills out from under a stationary cursor.
    private func updateVerticalHover(at point: NSPoint) {
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

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard isVertical, maxVerticalScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Mirror of the top bar, along Y. Trackpads report both axes on a diagonal
        // swipe, so take whichever the user moved further and let a horizontal
        // flick scroll the vertical strip too.
        let delta =
            abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        verticalScrollOffset -= delta
        clampVerticalScroll()
        // The pill under the cursor changed even though the cursor did not move.
        updateVerticalHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Keep the active workspace on screen — the vertical twin of the top bar's
    /// `scrollToActiveWorkspace`.
    private func scrollToSelectedVertical() {
        guard isVertical, verticalScrollViewportHeight > 0, selectedIndex >= 0,
            selectedIndex < items.count
        else {
            return
        }
        let step = Self.verticalItemSize + Self.verticalItemGap
        let top = Self.verticalTopInset + CGFloat(selectedIndex) * step
        if top < verticalScrollOffset {
            verticalScrollOffset = top
        } else if top + Self.verticalItemSize > verticalScrollOffset + verticalScrollViewportHeight {
            verticalScrollOffset = top + Self.verticalItemSize - verticalScrollViewportHeight
        }
        clampVerticalScroll()
    }

    // MARK: - Hit Testing

    private func hitTestItemIndex(at point: NSPoint) -> Int? {
        // The pinned `+` sits on top of the stack, so a pill scrolled underneath
        // it must not steal the hover or the click.
        if verticalPlusRect.contains(point) { return nil }
        // Staying on the already-expanded pill keeps it expanded — otherwise moving
        // toward its close button would collapse it out from under the cursor.
        if hoveredIndex >= 0, hoveredIndex < items.count,
            verticalHoveredPillRect(at: hoveredIndex).contains(point)
        {
            return hoveredIndex
        }
        for (i, _) in items.enumerated() {
            // Full strip width so the padding either side of the pill still hovers
            // the workspace it belongs to.
            let r = verticalItemRect(at: i)
            let strip = CGRect(
                x: verticalStripX, y: r.minY, width: Self.verticalWidth, height: r.height)
            if strip.contains(point) { return i }
        }
        return nil
    }

    private func isPlusButtonHit(at point: NSPoint) -> Bool {
        verticalPlusRect.contains(point)
    }

    private func handleVerticalClick(_ point: NSPoint) {
        // The pinned `+` overlays the bottom of the stack; it is handled by
        // `isPlusButtonHit` before we get here, so a pill behind it never matches.
        if verticalPlusRect.contains(point) { return }
        for (i, item) in items.enumerated() {
            // The hovered workspace is expanded, so its click target is the wide pill
            // the user can actually see, not the resting strip footprint.
            let pillRect =
                i == hoveredIndex ? verticalHoveredPillRect(at: i) : verticalItemRect(at: i)

            // The close button is inset on the pill's inner edge; test it before the
            // pill so a click on it isn't swallowed as a workspace selection.
            let closeRect = verticalCloseButtonRect(in: pillRect)
            if !item.isPinned && i == hoveredIndex && closeRect.contains(point) {
                delegate?.workspaceBar(self, didCloseAt: i)
                return
            }

            if pillRect.contains(point) {
                delegate?.workspaceBar(self, didSelectAt: i)
                return
            }
        }
    }
}
