import Cocoa

// MARK: - Drawing

extension StatusBarView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        let settings = AppSettings.shared
        let state = currentState

        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(bounds)

        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 0.5))

        let refFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let textY: CGFloat = round((barHeight - refFont.capHeight) / 2 - (refFont.ascender - refFont.capHeight))

        // Update all plugins
        for plugin in leftPlugins { plugin.update(state: state) }
        for plugin in rightPlugins { plugin.update(state: state) }

        // Reset tracking
        segmentRects.removeAll()

        // Draw left plugins left-to-right
        var x: CGFloat = 10
        var isFirst = true
        for plugin in leftPlugins where plugin.isVisible(settings: settings, state: state) {
            if !isFirst {
                // Thin vertical separator line
                let sepInset = round(barHeight * 0.22)
                x += 7
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
                ctx.fill(CGRect(x: x, y: sepInset, width: 0.5, height: barHeight - sepInset * 2))
                x += 7
            }

            let startX = x
            let width = plugin.draw(at: x, y: textY, theme: theme, settings: settings, state: state, ctx: ctx)
            x += width

            // Track hit rect for this segment
            let segRect = NSRect(x: startX - 4, y: 0, width: width + 8, height: barHeight)
            segmentRects[plugin.id] = segRect

            // Hover underline for clickable segments
            if hoveredSegmentID == plugin.id {
                let isClickable = plugin.associatedPanelID != nil || plugin is GitBranchSegment
                if isClickable {
                    ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.08).cgColor)
                    let hoverRect = CGRect(x: segRect.minX, y: 1, width: segRect.width, height: barHeight - 2)
                    ctx.addPath(CGPath(roundedRect: hoverRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                }
            }

            isFirst = false
        }

        // Draw sidebar toggle at far right
        let sidebarToggleWidth = drawSidebarToggle(ctx: ctx, theme: theme)

        // Split right plugins into panel icons (have associatedPanelID) and text segments
        let visibleRight = rightPlugins.filter { $0.isVisible(settings: settings, state: state) }
        let panelIcons = visibleRight.filter { $0.associatedPanelID != nil }
        let textSegments = visibleRight.filter { $0.associatedPanelID == nil }

        // Draw panel icons right-to-left, with gap from sidebar toggle separator
        let iconGap: CGFloat = 5
        var rx = bounds.width - sidebarToggleWidth + 2
        for plugin in panelIcons {
            let width = plugin.draw(at: rx, y: textY, theme: theme, settings: settings, state: state, ctx: ctx)
            rx -= width
            let iconRect = NSRect(x: rx, y: 0, width: width, height: barHeight)
            segmentRects[plugin.id] = iconRect

            // Hover highlight for plugin icons
            if hoveredSegmentID == plugin.id {
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.1).cgColor)
                let hoverRect = CGRect(x: iconRect.minX + 2, y: 2, width: iconRect.width - 4, height: barHeight - 4)
                ctx.addPath(CGPath(roundedRect: hoverRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }

        }
        // Draw separator between panel icons and text segments
        if !panelIcons.isEmpty {
            let sepInset = round(barHeight * 0.22)
            rx -= iconGap
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: rx, y: sepInset, width: 0.5, height: barHeight - sepInset * 2))
            rx -= iconGap
        }

        // Draw text segments (time, pane info, etc.) right-to-left
        for plugin in textSegments {
            let width = plugin.draw(at: rx, y: textY, theme: theme, settings: settings, state: state, ctx: ctx)
            rx -= width
            segmentRects[plugin.id] = NSRect(x: rx, y: 0, width: width, height: barHeight)
        }
    }

    /// Draw the sidebar toggle button at the far right edge. Returns total width consumed (including separator).
    internal func drawSidebarToggle(ctx: CGContext, theme: TerminalTheme) -> CGFloat {
        if sidebarToggleHidden {
            sidebarToggleRect = .zero
            return 10
        }
        let rightPadding: CGFloat = 10
        let sepGap: CGFloat = 8
        let iconDrawSize: CGFloat = 15
        let toggleZoneWidth = sepGap + iconDrawSize + rightPadding
        let totalWidth = sepGap + 1 + toggleZoneWidth

        // Separator line
        let sepInset = round(barHeight * 0.22)
        let sepX = bounds.width - totalWidth + sepGap
        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.25).cgColor)
        ctx.fill(CGRect(x: sepX, y: sepInset, width: 0.5, height: barHeight - sepInset * 2))

        // Hover highlight for sidebar toggle
        if isSidebarToggleHovered {
            let hoverRect = CGRect(x: sepX + 2, y: 2, width: bounds.width - sepX - 4, height: barHeight - 4)
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.1).cgColor)
            ctx.addPath(CGPath(roundedRect: hoverRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }

        // Sidebar icon — centered in the zone after the separator
        let color =
            sidebarVisible
            ? theme.accentColor
            : theme.chromeMuted.withAlphaComponent(isSidebarToggleHovered ? 0.7 : 0.5)

        let zoneStart = sepX + 1
        let zoneWidth = bounds.width - zoneStart
        let iconX = zoneStart + (zoneWidth - iconDrawSize) / 2
        let iconH = iconDrawSize * 0.75
        let iconY = (barHeight - iconH) / 2

        // Draw sidebar icon (outline rectangle with vertical divider)
        let iconRect = CGRect(x: iconX, y: iconY, width: iconDrawSize, height: iconH)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.strokePath()

        // Vertical divider at 2/3
        let divX = iconX + iconDrawSize * 0.65
        ctx.move(to: CGPoint(x: divX, y: iconRect.minY + 1))
        ctx.addLine(to: CGPoint(x: divX, y: iconRect.maxY - 1))
        ctx.strokePath()

        // Fill right portion if sidebar visible
        if sidebarVisible {
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.fill(CGRect(x: divX, y: iconRect.minY + 1, width: iconX + iconDrawSize - divX - 1, height: iconH - 2))
        }

        // Track hit rect (whole zone after separator)
        sidebarToggleRect = NSRect(x: sepX, y: 0, width: bounds.width - sepX, height: barHeight)

        return totalWidth
    }

    // MARK: - Click Handling

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let settings = AppSettings.shared
        let state = currentState

        // Sidebar toggle (far right)
        if sidebarToggleRect.contains(point) {
            onSidebarToggle?()
            return
        }

        // Check right plugins first (icons at edge), then left.
        // Only check visible plugins — hidden plugins retain stale hitRects
        // from previous draws that can intercept clicks meant for shifted
        // visible segments.
        for plugin in rightPlugins where plugin.isVisible(settings: settings, state: state) {
            if plugin.handleClick(at: point, in: self) { return }
        }
        for plugin in leftPlugins where plugin.isVisible(settings: settings, state: state) {
            if plugin.handleClick(at: point, in: self) { return }
        }

        // Fall back to associatedPanelID-based toggle for segments that
        // don't handle clicks themselves but have a linked panel.
        let allPlugins: [StatusBarPlugin] = rightPlugins + leftPlugins
        for plugin in allPlugins {
            guard let panelID = plugin.associatedPanelID,
                let rect = segmentRects[plugin.id],
                rect.contains(point)
            else { continue }
            onSidebarPluginToggle?(panelID)
            return
        }
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
        let settings = AppSettings.shared
        let allPlugins: [StatusBarPlugin] = leftPlugins + rightPlugins

        for plugin in allPlugins {
            guard plugin.isVisible(settings: settings, state: state),
                let rect = segmentRects[plugin.id]
            else { continue }

            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)

            // Convert rect to screen coordinates for VoiceOver
            let windowRect = convert(rect, to: nil)
            if let screenRect = window?.convertToScreen(windowRect) {
                element.setAccessibilityFrame(screenRect)
            }

            // Label
            let label = plugin.accessibilitySegmentLabel(state: state) ?? plugin.id
            let isClickable = plugin.associatedPanelID != nil || plugin is GitBranchSegment
            let isActive = plugin.associatedPanelID.flatMap { visibleSidebarPlugins.contains($0) } ?? false

            if isClickable {
                element.setAccessibilityRole(.button)
                var fullLabel = label
                if isActive { fullLabel += ", selected" }
                element.setAccessibilityLabel(fullLabel)
            } else {
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(label)
            }

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
