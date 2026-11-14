import Cocoa

// MARK: - Drawing

extension WorkspaceBarView {
    override func draw(_ dirtyRect: NSRect) {
        // This view is only ever used as a vertical (left/right) bar; the top bar
        // is drawn by ToolbarView. Click/hit-test still support the horizontal
        // layout for tests, but there is no horizontal draw path.
        guard isVertical, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawVertical(ctx)
    }

    // MARK: - Vertical Drawing (left bar)

    private func drawVertical(_ ctx: CGContext) {
        let theme = booTheme

        // No fill and no edge stroke: like the toolbar and status bar, this is a
        // bare strip over the window backdrop. Only the pills carry chrome.

        // Resolved once, not per pill: `IslandMetrics.borderColor` re-reads the
        // theme and re-runs the chrome-border blend on every access.
        let islandBorder = theme.islandBorder

        // Clip the scrolling stack to its viewport so a pill straddling the bottom
        // edge is cut off cleanly instead of bleeding into the pinned `+`.
        ctx.saveGState()
        ctx.clip(
            to: CGRect(x: 0, y: 0, width: bounds.width, height: verticalScrollViewportHeight))

        drawGroupHeaders(ctx, theme: theme)

        for (i, item) in items.enumerated() {
            let isSelected = i == selectedIndex
            // The hovered workspace is painted separately, expanded, after this loop
            // so it floats above its neighbours instead of being overdrawn by them.
            if i == hoveredIndex || hiddenRows.contains(i) { continue }
            let wsColor = item.resolvedColor

            let pillRect = verticalItemRect(at: i)
            // Skip pills scrolled out of the stack's viewport — nothing to paint, and
            // it keeps the cost flat as the workspace count grows.
            if pillRect.maxY < 0 || pillRect.minY > verticalScrollViewportHeight { continue }

            // The dragged pill stays as a faint placeholder; the ghost carries it.
            let isLifted =
                isDragging && (dragSourceIndex == i || (item.groupID != nil && item.groupID == draggedGroupID))
            if isLifted {
                ctx.saveGState()
                ctx.setAlpha(0.3)
            }
            defer { if isLifted { ctx.restoreGState() } }

            // Identical fill + accent border as the top bar, via the shared
            // WorkspacePillStyle. Only the square geometry differs here.
            WorkspacePillStyle.fill(
                ctx, rect: pillRect, active: isSelected, hovered: false,
                wsColor: wsColor, neutral: theme.chromeMuted)
            // Like the top bar: only the active workspace carries a border.
            if isSelected {
                WorkspacePillStyle.strokeBorder(ctx, rect: pillRect, theme: theme, color: wsColor)
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
            WorkspacePillStyle.drawStatus(
                ctx, rect: pillRect, hasActivity: item.hasActivity, progress: item.progress, theme: theme,
                inset: 4)
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
        drawExpandedHoverPill(ctx, theme: theme, islandBorder: islandBorder)

        // Plus button — pinned to the bottom, painted last so a pill scrolled to the
        // very end passes behind it.
        drawPlusButton(ctx, in: verticalPlusRect, theme: theme)

        // Draw drop insertion indicator
        if let dropIdx = dropTargetIndex {
            // At a group's first member the line sits above the group's tray.
            let header = groupHeaders.first { $0.members.lowerBound == dropIdx }
            let indicatorY = (header.map { groupTrayRect($0).minY } ?? verticalItemRect(at: dropIdx).minY) - 3
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fill(CGRect(x: verticalPillX, y: indicatorY, width: verticalPillWidth, height: 2))
        }
        drawStackHighlight(ctx, theme: theme)
    }

    /// Accent ring around an ungrouped stack-target pill. A grouped target, or a
    /// group header the drop would join, highlights its whole tray instead.
    private func drawStackHighlight(_ ctx: CGContext, theme: TerminalTheme) {
        guard let idx = dropStackIndex, items.indices.contains(idx), items[idx].groupID == nil else { return }
        WorkspacePillStyle.strokeDropRing(ctx, around: verticalItemRect(at: idx), theme: theme)
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
        WorkspacePillStyle.drawBackdropFade(
            ctx,
            in: CGRect(x: verticalStripX, y: y, width: Self.verticalWidth, height: height),
            from: CGPoint(x: 0, y: topDown ? y : y + height),
            to: CGPoint(x: 0, y: topDown ? y + height : y),
            backdrop: booTheme.windowBackdrop)
    }

    /// Paint the hovered workspace as a wide pill floating over the panes. Drawn
    /// after the resting stack so it sits on top of its neighbours, with a shadow to
    /// read as a layer above the content rather than a hole punched in the strip.
    private func drawExpandedHoverPill(
        _ ctx: CGContext, theme: TerminalTheme, islandBorder: NSColor
    ) {
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
        WorkspacePillStyle.fillRoundedRect(ctx, rect: rect)

        WorkspacePillStyle.fill(
            ctx, rect: rect, active: isSelected, hovered: true, wsColor: wsColor,
            neutral: theme.chromeMuted)
        // A hairline all the way round: with the shadow gone this is what separates
        // the floating pill from the terminal content behind it. The active
        // workspace keeps its accent stroke instead.
        if isSelected {
            WorkspacePillStyle.strokeBorder(ctx, rect: rect, theme: theme, color: wsColor)
        } else {
            WorkspacePillStyle.strokeIslandBorder(
                ctx, rect: rect, wsColor: wsColor, neutral: islandBorder)
        }

        // `chromeText` as `muted` too: the expanded pill's un-selected fallback is
        // full-strength text, unlike the resting pills' muted two-letter label.
        let textColor = WorkspacePillStyle.labelColor(
            wsColor: wsColor, active: isSelected, text: theme.chromeText,
            muted: theme.chromeText)

        let sidePad = Self.verticalHoveredPillPadding
        // The close button takes the end facing the panes: trailing on a left bar,
        // leading on a right bar. The name stops short of its column so a long one
        // truncates instead of colliding with it.
        let closeCol = item.isPinned ? sidePad : Self.verticalHoveredPillCloseSlot
        let textX = isRightAligned ? rect.minX + closeCol : rect.minX + sidePad
        let textW = rect.width - sidePad - closeCol

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
                tint: wsColor ?? theme.chromeMuted, hovered: isCloseButtonHovered)
        }
        // The close button owns its slot on hover, so the dot only shows on pinned pills.
        WorkspacePillStyle.drawStatus(
            ctx, rect: rect, hasActivity: item.hasActivity && item.isPinned, progress: item.progress,
            theme: theme)
    }

    // MARK: - Pin Icon

    private func drawPinIcon(_ ctx: CGContext, at origin: NSPoint, color: NSColor) {
        let iconSize: CGFloat = 7
        let iconRect = NSRect(x: origin.x, y: origin.y, width: iconSize, height: iconSize)
        if let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
            let sized = pinImage.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? pinImage
            sized.isTemplate = true
            sized.tinted(with: color.withAlphaComponent(0.5), size: iconRect.size).draw(in: iconRect)
        } else {
            ctx.setFillColor(color.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: origin.x + 1, y: origin.y + 1, width: 5, height: 5))
        }
    }

    // MARK: - Plus Button

    /// Hover close-button rect for a vertical pill: top corner away from the bar's
    /// edge — upper-right on the left bar, upper-left on the right bar. (Flipped view,
    /// so the top is `minY`.)
    func verticalCloseButtonRect(in pillRect: CGRect) -> CGRect {
        let circleSize = WorkspacePillStyle.closeButtonSize
        // Lives inside the *expanded* hover pill, at the end facing the panes. The
        // resting pill is only as wide as its two-letter label, so there is nowhere
        // to put it there without covering the text.
        let inset = Self.verticalHoveredPillCloseInset
        let circleX =
            isRightAligned ? pillRect.minX + inset : pillRect.maxX - circleSize - inset
        return CGRect(
            x: circleX, y: pillRect.midY - circleSize / 2, width: circleSize, height: circleSize)
    }

    private func drawPlusButton(_ ctx: CGContext, in rect: CGRect, theme: TerminalTheme) {
        if isPlusButtonHovered {
            ctx.setFillColor(theme.hoverFill.cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: rect)
        }

        let plusColor =
            isPlusButtonHovered
            ? theme.textSecondary
            : theme.textTertiary
        // The `+` fills a full pill-sized footprint, so it is larger than the tab bar's.
        WorkspacePillStyle.drawPlusGlyph(ctx, in: rect, halfSpan: 5, color: plusColor)
    }
}
