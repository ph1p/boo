import Cocoa

// MARK: - Drawing

extension StatusBarView {
    /// Only read for its `capHeight`/`ascender` to centre text vertically, which
    /// never varies — so it is built once rather than per draw pass. The status bar
    /// repaints on hover, putting this on the mouse-move path.
    nonisolated(unsafe) static let referenceFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    /// Gap on each side of a left-group separator line.
    static let separatorGap: CGFloat = 7
    /// Least empty space kept between the left and right groups.
    static let minGroupGap: CGFloat = 16

    /// Offscreen 1×1 context segments draw into while being measured. Their
    /// text goes through `safeDraw`, which targets the current NSGraphicsContext,
    /// so measuring swaps this in rather than passing a context around.
    private static let measureContext: NSGraphicsContext? = {
        guard
            let cg = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return NSGraphicsContext(cgContext: cg, flipped: true)
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let settings = AppSettings.shared
        let state = currentState

        // Nothing of its own: no fill, no border, no top separator. The bar is a
        // bare strip over the window backdrop, and the island gap above it does the
        // separating that the old rule used to.

        let textY = IslandMetrics.capCenteredTitleY(font: Self.referenceFont, barHeight: barHeight)

        // Update all plugins
        for plugin in leftPlugins { plugin.update(state: state) }
        for plugin in rightPlugins { plugin.update(state: state) }

        // Reset tracking
        drawnSegments.removeAll()

        // Sidebar toggle sits at the edge the sidebar is on
        let toggleLeading = settings.sidebarPosition == .left
        let sidebarToggleWidth = drawSidebarToggle(ctx: ctx, theme: theme, leading: toggleLeading)
        let leftStart: CGFloat = toggleLeading ? sidebarToggleWidth : IslandMetrics.contentInset
        let rightEnd = bounds.width - (toggleLeading ? IslandMetrics.contentInset : sidebarToggleWidth) + 2

        // Place: user order and sides, then measure, then drop what doesn't fit.
        let placed = placedSegments(settings: settings, state: state)
        var native: [String: CGFloat] = [:]
        for plugin in placed.left + placed.right {
            native[plugin.id] = measure(plugin, y: textY, theme: theme, settings: settings, state: state)
        }
        // Left-native segments report bare content width; right-native ones
        // include 4pt padding either side. Convert to the side they sit on.
        func leftWidth(_ p: StatusBarPlugin) -> CGFloat {
            let w = native[p.id] ?? 0
            return p.position == .left ? w : max(0, w - 8)
        }
        func rightWidth(_ p: StatusBarPlugin) -> CGFloat {
            let w = native[p.id] ?? 0
            return p.position == .right ? w : w + 8
        }
        let left = placed.left.filter { (native[$0.id] ?? 0) > 0 }
        let right = placed.right.filter { (native[$0.id] ?? 0) > 0 }
        let dropped = StatusBarLayout.overflow(
            left: left.map { .init(id: $0.id, width: leftWidth($0), collapsePriority: $0.collapsePriority) },
            right: right.map { .init(id: $0.id, width: rightWidth($0), collapsePriority: $0.collapsePriority) },
            available: rightEnd - leftStart, separator: Self.separatorGap * 2, minGap: Self.minGroupGap)
        collapsedSegmentIDs = dropped

        // Right group first, so the left group knows where it has to stop.
        var rx = rightEnd
        for plugin in right.reversed() where !dropped.contains(plugin.id) {
            let width = rightWidth(plugin)
            let rect = NSRect(x: rx - width, y: 0, width: width, height: barHeight)
            drawHover(for: plugin, in: rect, theme: theme, ctx: ctx)
            let anchor = plugin.position == .right ? rx : rect.minX + 4
            _ = plugin.draw(at: anchor, y: textY, theme: theme, settings: settings, state: state, ctx: ctx)
            record(plugin, rect: rect)
            rx -= width
        }

        // Left group, clipped so a lone segment too wide to fit can't run under
        // the right group.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: max(0, rx - Self.minGroupGap / 2), height: barHeight))
        var x = leftStart
        var isFirst = true
        for plugin in left where !dropped.contains(plugin.id) {
            if !isFirst {
                x += Self.separatorGap
                if settings.statusBarSeparators {
                    let sepInset = round(barHeight * 0.22)
                    ctx.setFillColor(theme.separator.cgColor)
                    ctx.fill(CGRect(x: x, y: sepInset, width: 0.5, height: barHeight - sepInset * 2))
                }
                x += Self.separatorGap
            }
            let width = leftWidth(plugin)
            let rect = NSRect(x: x - 4, y: 0, width: width + 8, height: barHeight)
            drawHover(for: plugin, in: rect, theme: theme, ctx: ctx)
            let anchor = plugin.position == .left ? x : x + width + 4
            _ = plugin.draw(at: anchor, y: textY, theme: theme, settings: settings, state: state, ctx: ctx)
            record(plugin, rect: rect)
            x += width
            isFirst = false
        }
        ctx.restoreGState()

        updateClockTimer(settings: settings)
    }

    /// Visible segments per side, in visual left-to-right order.
    func placedSegments(
        settings: AppSettings, state: StatusBarState
    ) -> (
        left: [StatusBarPlugin], right: [StatusBarPlugin]
    ) {
        let arrangement = arrangement(settings: settings)
        let byID = pluginsByID
        func shown(_ ids: [String]) -> [StatusBarPlugin] {
            ids.compactMap { byID[$0] }.filter {
                $0.isVisible(settings: settings, state: state) && !settings.isStatusBarSegmentHidden($0.id)
            }
        }
        return (shown(arrangement.left), shown(arrangement.right))
    }

    /// Width a segment would draw at, found by drawing it offscreen.
    private func measure(
        _ plugin: StatusBarPlugin, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState
    ) -> CGFloat {
        guard let measureContext = Self.measureContext else { return 0 }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = measureContext
        defer { NSGraphicsContext.current = previous }
        let cg = measureContext.cgContext
        cg.saveGState()
        defer { cg.restoreGState() }
        // Right-native segments draw leftwards from their anchor; keep them on
        // positive x so nothing they compute from it goes negative.
        let anchor: CGFloat = plugin.position == .right ? 10_000 : 0
        return plugin.draw(at: anchor, y: y, theme: theme, settings: settings, state: state, ctx: cg)
    }

    private func drawHover(for plugin: StatusBarPlugin, in rect: NSRect, theme: TerminalTheme, ctx: CGContext) {
        guard hoveredSegmentID == plugin.id, plugin.isClickable else { return }
        ctx.setFillColor(theme.hoverFill.cgColor)
        WorkspacePillStyle.fillRoundedRect(
            ctx, rect: CGRect(x: rect.minX, y: 1, width: rect.width, height: barHeight - 2))
    }

    private func record(_ plugin: StatusBarPlugin, rect: NSRect) {
        drawnSegments.append((plugin, rect))
    }

    /// The drawn segment under `point`, if any.
    func segment(at point: NSPoint) -> StatusBarPlugin? {
        drawnSegments.first { $0.rect.contains(point) }?.plugin
    }

    /// Draw the sidebar toggle button at the far left (`leading`) or far right
    /// edge. Returns total width consumed (including separator).
    internal func drawSidebarToggle(ctx: CGContext, theme: TerminalTheme, leading: Bool) -> CGFloat {
        if sidebarToggleHidden {
            sidebarToggleRect = .zero
            return IslandMetrics.contentInset
        }
        let rightPadding: CGFloat = IslandMetrics.contentInset
        let sepGap: CGFloat = 8
        let iconDrawSize: CGFloat = 15
        let toggleZoneWidth = sepGap + iconDrawSize + rightPadding
        let totalWidth = sepGap + 1 + toggleZoneWidth

        // Separator line between the toggle zone and the segments
        let sepInset = round(barHeight * 0.22)
        let sepX = leading ? totalWidth - sepGap - 1 : bounds.width - totalWidth + sepGap
        ctx.setFillColor(theme.separator.cgColor)
        ctx.fill(CGRect(x: sepX, y: sepInset, width: 0.5, height: barHeight - sepInset * 2))

        // Zone between the bar edge and the separator
        let zoneStart = leading ? 0 : sepX + 1
        let zoneWidth = leading ? sepX : bounds.width - zoneStart

        // Hover highlight for sidebar toggle
        if isSidebarToggleHovered {
            let hoverRect = CGRect(x: zoneStart + 2, y: 2, width: zoneWidth - 3, height: barHeight - 4)
            ctx.setFillColor(theme.hoverFill.cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: hoverRect)
        }

        // Sidebar icon — centered in the zone after the separator
        let color =
            sidebarVisible
            ? theme.accentColor
            : (isSidebarToggleHovered ? theme.textSecondary : theme.textTertiary)

        let iconX = zoneStart + (zoneWidth - iconDrawSize) / 2
        let iconH = iconDrawSize * 0.75
        let iconY = (barHeight - iconH) / 2

        // Draw sidebar icon (outline rectangle with vertical divider)
        let iconRect = CGRect(x: iconX, y: iconY, width: iconDrawSize, height: iconH)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.strokePath()

        // Vertical divider a third in from the side the sidebar is on
        let sidebarLeft = AppSettings.shared.sidebarPosition == .left
        let divX = iconX + iconDrawSize * (sidebarLeft ? 0.35 : 0.65)
        ctx.move(to: CGPoint(x: divX, y: iconRect.minY + 1))
        ctx.addLine(to: CGPoint(x: divX, y: iconRect.maxY - 1))
        ctx.strokePath()

        // Fill the sidebar portion if sidebar visible
        if sidebarVisible {
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            let fillRect =
                sidebarLeft
                ? CGRect(x: iconX + 1, y: iconRect.minY + 1, width: divX - iconX - 1, height: iconH - 2)
                : CGRect(x: divX, y: iconRect.minY + 1, width: iconX + iconDrawSize - divX - 1, height: iconH - 2)
            ctx.fill(fillRect)
        }

        // Track hit rect (whole zone after separator)
        sidebarToggleRect = NSRect(x: zoneStart, y: 0, width: zoneWidth + 1, height: barHeight)

        return totalWidth
    }

    // MARK: - Click Handling

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Sidebar toggle (edge on the sidebar's side)
        if sidebarToggleRect.contains(point) {
            onSidebarToggle?()
            return
        }

        // Only the segment drawn under the point gets the click. Hidden and
        // collapsed segments keep stale hit rects from earlier draws, which
        // must not intercept clicks meant for whatever shifted into their place.
        if let plugin = segment(at: point), plugin.handleClick(at: point, in: self) { return }

        // Empty space — drag the window, same as the toolbar.
        window?.performDrag(with: event)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .toolbar }
    override func accessibilityLabel() -> String? { "Status bar" }

    override func accessibilityChildren() -> [Any]? {
        rebuildAccessibilityElements()
        return accessibilityElements
    }

    internal func rebuildAccessibilityElements() {
        accessibilityElements.removeAll()
        let state = currentState

        for (plugin, rect) in drawnSegments.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)

            // Convert rect to screen coordinates for VoiceOver
            let windowRect = convert(rect, to: nil)
            if let screenRect = window?.convertToScreen(windowRect) {
                element.setAccessibilityFrame(screenRect)
            }

            // Label
            let label = plugin.accessibilitySegmentLabel(state: state) ?? plugin.displayName
            element.setAccessibilityRole(plugin.isClickable ? .button : .staticText)
            element.setAccessibilityLabel(label)

            accessibilityElements.append(element)
        }

        // Sidebar toggle button
        let toggleElement = NSAccessibilityElement()
        toggleElement.setAccessibilityParent(self)
        let toggleWindowRect = convert(sidebarToggleRect, to: nil)
        if let screenRect = window?.convertToScreen(toggleWindowRect) {
            toggleElement.setAccessibilityFrame(screenRect)
        }
        toggleElement.setAccessibilityRole(.button)
        toggleElement.setAccessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
        accessibilityElements.append(toggleElement)
    }

}
