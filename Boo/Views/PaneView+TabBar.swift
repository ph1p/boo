import Cocoa

extension PaneView {

    // MARK: - Font Cache

    private enum TabFonts {
        nonisolated(unsafe) static let title10Regular = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        nonisolated(unsafe) static let title10Medium = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        nonisolated(unsafe) static let close8Bold = NSFont.systemFont(ofSize: 8, weight: .bold)
        nonisolated(unsafe) static let plus15Light = NSFont.systemFont(ofSize: 15, weight: .light)
        nonisolated(unsafe) static let groupChip = NSFont.systemFont(ofSize: 10, weight: .semibold)
        nonisolated(unsafe) static let groupBadge = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    }

    // MARK: - Tab Groups

    private static let groupChipPadX: CGFloat = 8
    private static let groupDotSize: CGFloat = 6
    private static let groupDotGap: CGFloat = 5

    /// Chip content: a dot and the name while expanded; the name and a tab
    /// count badge while collapsed. An unnamed group drops the name.
    private func groupChipContentWidth(_ group: TabGroup) -> CGFloat {
        let nameW =
            group.name.isEmpty
            ? 0 : ceil((group.name as NSString).size(withAttributes: [.font: TabFonts.groupChip]).width)
        if group.isCollapsed {
            return (nameW > 0 ? nameW + Self.groupDotGap : 0) + groupBadgeWidth(group)
        }
        return Self.groupDotSize + (nameW > 0 ? Self.groupDotGap + nameW : 0)
    }

    private func groupBadgeWidth(_ group: TabGroup) -> CGFloat {
        let count = "\(pane.tabIndices(inGroup: group.id).count)" as NSString
        return max(14, ceil(count.size(withAttributes: [.font: TabFonts.groupBadge]).width) + 8)
    }

    /// Width of the group chip at the start of tab `index`'s slot; 0 unless
    /// the tab opens a group.
    func groupChipWidth(at index: Int) -> CGFloat {
        guard pane.isFirstTabOfGroup(at: index), let group = pane.group(id: pane.tabs[index].groupID) else { return 0 }
        return min(tabMaxWidth, groupChipContentWidth(group) + Self.groupChipPadX * 2 + Self.tabPillInsetX * 2)
    }

    /// Slot of tab `index` in view coordinates (scroll offset applied).
    func tabSlotRect(at index: Int) -> CGRect? {
        if isVerticalTabs { return verticalSlotRect(at: index) }
        if AppSettings.shared.tabOverflowMode == .wrap {
            let layouts = wrapLayout()
            guard index < layouts.count else { return nil }
            let lay = layouts[index]
            return CGRect(x: lay.x, y: lay.y, width: lay.width, height: singleRowTabHeight)
        }
        let widths = allTabWidths()
        guard index < widths.count else { return nil }
        return CGRect(
            x: tabStartX(index, widths: widths) - tabScrollOffset, y: 0, width: widths[index], height: tabBarHeight)
    }

    /// Pill of tab `index` in view coordinates; nil while its group is collapsed.
    func visibleTabPillRect(at index: Int) -> CGRect? {
        guard !pane.isTabHidden(at: index), var slot = tabSlotRect(at: index) else { return nil }
        if isVerticalTabs { return verticalPillRect(inRow: verticalRowRect(inSlot: slot, index: index)) }
        let chipW = groupChipWidth(at: index)
        slot.origin.x += chipW
        slot.size.width -= chipW
        return Self.tabPillRect(inSlot: slot)
    }

    /// The chip of group `id` in view coordinates (the header row in vertical mode).
    func groupChipRect(for id: UUID) -> CGRect? {
        guard let first = pane.tabs.firstIndex(where: { $0.groupID == id }), let slot = tabSlotRect(at: first)
        else { return nil }
        if isVerticalTabs {
            return verticalGroupHeaderPill(
                CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: Self.verticalGroupHeaderHeight))
        }
        return Self.tabPillRect(
            inSlot: CGRect(x: slot.minX, y: slot.minY, width: groupChipWidth(at: first), height: slot.height))
    }

    /// The group whose chip is under `point`, given the tab slot it is in.
    func groupChipHit(at point: NSPoint, tabIndex idx: Int) -> UUID? {
        if isVerticalTabs {
            guard pane.isFirstTabOfGroup(at: idx), let slot = tabSlotRect(at: idx),
                point.y < slot.minY + Self.verticalGroupHeaderHeight
            else { return nil }
            return pane.tabs[idx].groupID
        }
        let chipW = groupChipWidth(at: idx)
        guard chipW > 0, let slot = tabSlotRect(at: idx), point.x < slot.minX + chipW else { return nil }
        return pane.tabs[idx].groupID
    }

    func groupTint(_ group: TabGroup, theme: TerminalTheme) -> NSColor {
        group.color.nsColor ?? theme.accentColor
    }

    /// Black or white, whichever reads better on a solid `color` fill.
    static func contrastingText(on color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? NSColor.black.withAlphaComponent(0.85) : .white
    }

    /// Tinted backdrop behind an expanded group's chip and tabs, one per row,
    /// so the group reads as a single unit.
    func drawGroupContainers(ctx: CGContext, theme: TerminalTheme) {
        for group in pane.groups where !group.isCollapsed {
            var rows: [CGRect] = []
            for i in pane.tabIndices(inGroup: group.id) {
                guard let slot = tabSlotRect(at: i), slot.width > 0 else { continue }
                if let last = rows.last, last.minY == slot.minY {
                    rows[rows.count - 1] = last.union(slot)
                } else {
                    rows.append(slot)
                }
            }
            let tint = groupTint(group, theme: theme)
            let dragged = groupDropIndex != nil && groupPressID == group.id
            for row in rows {
                let padY = (row.height - Self.tabPillHeight) / 2 - 2
                let rect = CGRect(
                    x: row.minX + 1, y: row.minY + padY, width: row.width - 2, height: Self.tabPillHeight + 4)
                drawGroupBackdrop(ctx, rect: rect, tint: tint, faded: dragged)
            }
        }
    }

    func drawGroupBackdrop(_ ctx: CGContext, rect: CGRect, tint: NSColor, faded: Bool) {
        let radius = WorkspacePillStyle.cornerRadius + 2
        ctx.setFillColor(tint.withAlphaComponent(faded ? 0.04 : 0.09).cgColor)
        WorkspacePillStyle.fillRoundedRect(ctx, rect: rect, radius: radius)
        ctx.setStrokeColor(tint.withAlphaComponent(faded ? 0.15 : 0.32).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(
            CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5,
                transform: nil))
        ctx.strokePath()
    }

    func drawGroupChip(
        ctx: CGContext, theme: TerminalTheme, group: TabGroup, x: CGFloat, y: CGFloat, width: CGFloat, rowH: CGFloat,
        hovered: Bool
    ) {
        let pill = Self.tabPillRect(inSlot: CGRect(x: x, y: y, width: width, height: rowH))
        let tint = groupTint(group, theme: theme)
        let text: NSColor
        if group.isCollapsed {
            ctx.setFillColor(tint.withAlphaComponent(hovered ? 1 : 0.85).cgColor)
            text = Self.contrastingText(on: tint)
        } else {
            ctx.setFillColor(tint.withAlphaComponent(hovered ? 0.34 : 0.22).cgColor)
            text = theme.chromeText
        }
        WorkspacePillStyle.fillRoundedRect(ctx, rect: pill)

        var cx = pill.minX + Self.groupChipPadX
        if !group.isCollapsed {
            if group.name.isEmpty { cx = pill.midX - Self.groupDotSize / 2 }
            ctx.setFillColor(tint.cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: cx, y: pill.midY - Self.groupDotSize / 2, width: Self.groupDotSize, height: Self.groupDotSize))
            cx += Self.groupDotSize + Self.groupDotGap
        }
        let badgeW = group.isCollapsed ? groupBadgeWidth(group) : 0
        if !group.isCollapsed || !group.name.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: TabFonts.groupChip, .foregroundColor: text, .paragraphStyle: para
            ]
            let label = group.name as NSString
            let size = label.size(withAttributes: attrs)
            let room = pill.maxX - Self.groupChipPadX - cx - (badgeW > 0 ? badgeW + Self.groupDotGap : 0)
            label.draw(
                in: CGRect(
                    x: cx, y: pill.midY - size.height / 2, width: max(0, min(size.width, room)), height: size.height),
                withAttributes: attrs)
        }
        if badgeW > 0 {
            let badge = CGRect(
                x: group.name.isEmpty ? pill.midX - badgeW / 2 : pill.maxX - Self.groupChipPadX - badgeW,
                y: pill.midY - 7, width: badgeW, height: 14)
            ctx.setFillColor(text.withAlphaComponent(0.2).cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: badge, radius: 7)
            let attrs: [NSAttributedString.Key: Any] = [.font: TabFonts.groupBadge, .foregroundColor: text]
            let count = "\(pane.tabIndices(inGroup: group.id).count)" as NSString
            let size = count.size(withAttributes: attrs)
            count.draw(
                at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// Insertion marker while a group is dragged by its chip, in the group's color.
    func drawGroupDropIndicator(ctx: CGContext, theme: TerminalTheme) {
        guard let index = groupDropIndex, let group = pane.group(id: groupPressID) else { return }
        let pos = tabInsertionPosition(at: index)
        ctx.setFillColor(groupTint(group, theme: theme).cgColor)
        if isVerticalTabs {
            WorkspacePillStyle.fillRoundedRect(
                ctx, rect: CGRect(x: pos.x + 4, y: pos.y - 1, width: verticalTabColumnWidth - pos.x * 2 - 8, height: 2),
                radius: 1)
        } else {
            let midY = tabInsertionRowCenterY(at: index)
            WorkspacePillStyle.fillRoundedRect(
                ctx, rect: CGRect(x: pos.x - 1, y: midY - Self.tabPillHeight / 2, width: 2, height: Self.tabPillHeight),
                radius: 1)
        }
    }

    // MARK: - Pill Metrics

    /// Horizontal inset of the pill inside its tab slot — two adjacent slots yield
    /// a `2 × tabPillInsetX` gap between pills.
    static let tabPillInsetX: CGFloat = 3
    /// Height of a tab pill, vertically centred in the tab row.
    static let tabPillHeight: CGFloat = 22
    /// Inset of the first/last tab slot from the pane edge. Together with
    /// `tabPillInsetX` the outermost pills sit `tabBarSideInset + tabPillInsetX`
    /// from the pane edge — the same 6pt the pills keep between each other.
    static let tabBarSideInset: CGFloat = 3
    /// Lead-in from the pill's left edge to its first content (icon or title).
    static let tabTextLeadIn: CGFloat = 10
    /// Width a leading icon advances the title by (12pt glyph + 3pt gap).
    static let tabIconAdvance: CGFloat = 15
    /// Trailing gap between the close circle and the pill's right edge.
    static let tabCloseTrailingGap: CGFloat = 4
    /// Slot-relative width of the close-button hit zone at the tab's right edge —
    /// derived from the drawn circle so draw, hover, and click can't diverge.
    static let tabCloseHitZone: CGFloat =
        tabPillInsetX + tabCloseTrailingGap + WorkspacePillStyle.closeButtonSize

    /// The pill drawn inside a tab or plus slot — the one place the pill inset
    /// geometry lives.
    static func tabPillRect(inSlot slot: CGRect) -> CGRect {
        slot.insetBy(dx: tabPillInsetX, dy: (slot.height - tabPillHeight) / 2)
    }

    // MARK: - Tab Bar Drawing

    func drawTabsScrollable(ctx: CGContext, theme: TerminalTheme, barH: CGFloat) {
        let inset = Self.tabBarSideInset
        let widths = allTabWidths()
        let maxScroll = scrollMaxOffset(widths: widths)
        let isOverflowing = maxScroll > 0
        // When overflowing, the plus pins in front of the right side inset and
        // the scrollable strip clips just before it.
        let pinnedPlusX = bounds.width - plusButtonWidth - inset

        // Clamp and auto-scroll to active tab only when active tab changes
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        if isOverflowing && pane.activeTabIndex != lastAutoScrolledTabIndex {
            lastAutoScrolledTabIndex = pane.activeTabIndex
            let activeStart = tabStartX(pane.activeTabIndex, widths: widths) - tabScrollOffset
            let activeEnd = activeStart + widths[pane.activeTabIndex]
            if activeStart < inset {
                tabScrollOffset += activeStart - inset
            } else if activeEnd > pinnedPlusX {
                tabScrollOffset += activeEnd - pinnedPlusX
            }
            tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        } else if !isOverflowing {
            tabScrollOffset = 0
        }

        // Clip scrollable tabs so they don't draw over the pinned plus button
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: pinnedPlusX, height: barH + 1))

        drawGroupContainers(ctx: ctx, theme: theme)
        var x: CGFloat = inset - tabScrollOffset
        for (i, tab) in pane.tabs.enumerated() {
            let isActive = i == pane.activeTabIndex
            drawSingleTab(
                ctx: ctx, theme: theme, tab: tab, index: i, x: x, y: 0,
                width: widths[i], rowH: barH, isActive: isActive)
            x += widths[i]
        }

        // Scroll fades — same treatment as the workspace strip in the toolbar:
        // dissolve clipped tabs into the bar background on whichever side has
        // more tabs hidden. The bar shares the terminal background, so the fade
        // uses that colour, not the window backdrop.
        if isOverflowing {
            if tabScrollOffset > 0 {
                WorkspacePillStyle.drawFade(
                    ctx, in: CGRect(x: 0, y: 0, width: 20, height: barH),
                    from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 0),
                    color: theme.background.nsColor)
            }
            if tabScrollOffset < maxScroll {
                let fadeW: CGFloat = 32
                WorkspacePillStyle.drawFade(
                    ctx, in: CGRect(x: pinnedPlusX - fadeW, y: 0, width: fadeW, height: barH),
                    from: CGPoint(x: pinnedPlusX, y: 0), to: CGPoint(x: pinnedPlusX - fadeW, y: 0),
                    color: theme.background.nsColor)
            }
        }
        drawGroupDropIndicator(ctx: ctx, theme: theme)

        ctx.restoreGState()

        let plusSlot = plusButtonSlot(widths: widths)
        drawPlusButton(
            ctx: ctx, theme: theme, x: plusSlot.minX, y: plusSlot.minY, width: plusSlot.width, rowH: plusSlot.height)
    }

    func drawTabsWrapped(ctx: CGContext, theme: TerminalTheme) {
        tabScrollOffset = 0
        let widths = allTabWidths()
        let layouts = wrapLayout(widths: widths)

        drawGroupContainers(ctx: ctx, theme: theme)
        for (i, tab) in pane.tabs.enumerated() {
            guard i < layouts.count else { break }
            let lay = layouts[i]
            let isActive = i == pane.activeTabIndex
            drawSingleTab(
                ctx: ctx, theme: theme, tab: tab, index: i, x: lay.x, y: lay.y,
                width: lay.width, rowH: singleRowTabHeight, isActive: isActive)
        }
        drawGroupDropIndicator(ctx: ctx, theme: theme)

        let plusSlot = plusButtonSlot(layouts: layouts)
        drawPlusButton(
            ctx: ctx, theme: theme, x: plusSlot.minX, y: plusSlot.minY, width: plusSlot.width, rowH: plusSlot.height)
    }

    /// Slot rect of the `+` button in the current overflow mode — the ONE place
    /// that knows where the plus sits. Draw and hit-test both read it.
    /// Scroll mode: follows the last tab while everything fits, pins in front of
    /// the right side inset once the strip overflows. Wrap mode: after the last
    /// tab, or on a row of its own when it doesn't fit.
    func plusButtonSlot(widths: [CGFloat]? = nil) -> CGRect {
        let inset = Self.tabBarSideInset
        if isVerticalTabs { return verticalPlusSlot }
        let w = widths ?? allTabWidths()
        if AppSettings.shared.tabOverflowMode == .wrap {
            return plusButtonSlot(layouts: wrapLayout(widths: w))
        }
        let isOverflowing = scrollMaxOffset(widths: w) > 0
        let x = isOverflowing ? bounds.width - plusButtonWidth - inset : inset + w.reduce(0, +)
        return CGRect(x: x, y: 0, width: plusButtonWidth, height: tabBarHeight)
    }

    /// Wrap-mode plus slot for callers that already computed the layouts.
    func plusButtonSlot(layouts: [TabLayout]) -> CGRect {
        let inset = Self.tabBarSideInset
        let lastLay = layouts.last
        if plusFitsOnLastRow(layouts) {
            return CGRect(
                x: (lastLay?.x ?? inset) + (lastLay?.width ?? 0), y: lastLay?.y ?? inset,
                width: plusButtonWidth, height: singleRowTabHeight)
        }
        return CGRect(
            x: inset, y: (lastLay?.y ?? inset) + singleRowTabHeight,
            width: plusButtonWidth, height: singleRowTabHeight)
    }

    func drawSingleTab(
        ctx: CGContext, theme: TerminalTheme, tab: Pane.Tab, index: Int, x: CGFloat, y: CGFloat,
        width: CGFloat, rowH: CGFloat, isActive: Bool
    ) {
        var x = x
        var width = width
        let group = pane.group(id: tab.groupID)
        // The group being dragged by its chip fades while it is in flight.
        let inFlight = group != nil && groupDropIndex != nil && groupPressID == group?.id
        if inFlight {
            ctx.saveGState()
            ctx.setAlpha(0.45)
        }
        defer { if inFlight { ctx.restoreGState() } }
        let chipW = groupChipWidth(at: index)
        if let group, chipW > 0 {
            drawGroupChip(
                ctx: ctx, theme: theme, group: group, x: x, y: y, width: chipW, rowH: rowH,
                hovered: hoveredTabIndex == index && isGroupChipHovered)
            x += chipW
            width -= chipW
        }
        guard width > 0, !pane.isTabHidden(at: index) else { return }
        let tabRect = CGRect(x: x, y: y, width: width, height: rowH)
        let isHovered = hoveredTabIndex == index && !isGroupChipHovered

        // Pill inside the tab slot — the horizontal inset supplies the gap between
        // neighbouring pills, the vertical one keeps the pill off the bar edges.
        let pillRect = Self.tabPillRect(inSlot: tabRect)
        WorkspacePillStyle.fill(
            ctx, rect: pillRect, active: isActive, hovered: isHovered,
            wsColor: nil, neutral: theme.chromeMuted)
        if selectedTabIDs.contains(tab.id) {
            WorkspacePillStyle.strokeHairline(ctx, rect: pillRect, color: theme.accentColor)
        }

        let midY = y + rowH / 2
        var textX = pillRect.minX + Self.tabTextLeadIn

        // Close button visible on hover or active tab (when closeable)
        let showClose = showTabClose && (isActive || isHovered)
        let closeZone: CGFloat = showClose ? 18 : 8

        textX += drawLeadingIcon(tab: tab, theme: theme, x: textX, midY: midY, isActive: isActive)

        // Title — use truncating tail paragraph style for automatic ellipsis
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: isActive ? TabFonts.title10Medium : TabFonts.title10Regular,
            .foregroundColor: isActive
                ? theme.chromeText : (isHovered ? theme.chromeText.withAlphaComponent(0.8) : theme.chromeMuted),
            .paragraphStyle: para
        ]
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let titleSize = title.size(withAttributes: attrs)
        let maxTitleW = max(0, pillRect.maxX - textX - closeZone)
        title.draw(
            in: CGRect(
                x: textX, y: midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW), height: titleSize.height),
            withAttributes: attrs)

        // OSC 9;4 progress along the pill's bottom edge.
        if let progress = tab.state.progress {
            let bar = CGRect(
                x: pillRect.minX + 6, y: pillRect.maxY - ProgressBarStyle.height - 1,
                width: pillRect.width - 12, height: ProgressBarStyle.height)
            ProgressBarStyle.draw(ctx, progress: progress, in: bar, theme: theme)
        }

        // Profile accent along the pill's bottom edge; progress takes that spot.
        if tab.state.progress == nil, let name = tab.state.profile,
            let accent = ProfileStore.shared.accent(forProfile: name)
        {
            ctx.setFillColor(accent.cgColor)
            let bar = CGRect(x: pillRect.minX + 8, y: pillRect.maxY - 2.5, width: pillRect.width - 16, height: 1.5)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
            ctx.fillPath()
        }

        if tab.state.isRecording { Self.drawRecordingDot(ctx, in: pillRect) }

        // Activity dot — shown on inactive tabs when a command finished in
        // background; a trigger's mark shows in the warning color.
        if tab.state.hasActivity && !isActive {
            let dotSize: CGFloat = 5
            ctx.setFillColor((tab.state.triggerMark != nil ? theme.warning : theme.accentEmphasis).cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: pillRect.maxX - closeZone - dotSize - 2,
                    y: midY - dotSize / 2,
                    width: dotSize, height: dotSize))
        }

        // Close button — only show on active or hovered tab
        if showClose {
            let closeHovered = isHovered && isCloseButtonHovered
            let closeAlpha: CGFloat = closeHovered ? 0.9 : (isActive ? 0.7 : 0.5)

            let circleSize = WorkspacePillStyle.closeButtonSize
            let circleCenterX = pillRect.maxX - circleSize / 2 - Self.tabCloseTrailingGap
            let circleCenterY = midY

            // Subtle circular background on close-button hover
            if closeHovered {
                let circleX = circleCenterX - circleSize / 2
                let circleY = circleCenterY - circleSize / 2
                ctx.setFillColor(theme.controlFill.cgColor)
                ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
            }

            let ca: [NSAttributedString.Key: Any] = [
                .font: TabFonts.close8Bold,
                .foregroundColor: theme.chromeMuted.withAlphaComponent(closeAlpha)
            ]
            let cs = "\u{2715}" as NSString
            let csz = cs.size(withAttributes: ca)
            cs.draw(
                at: NSPoint(x: circleCenterX - csz.width / 2, y: circleCenterY - csz.height / 2), withAttributes: ca)
        }
    }

    /// Draws the tab's content-type or process icon at `x`; returns how far
    /// the title moves right (0 without an icon).
    /// Red dot on the pill's top-left corner while the tab records.
    static func drawRecordingDot(_ ctx: CGContext, in pill: CGRect) {
        let size: CGFloat = 6
        ctx.setFillColor(AppSettings.shared.theme.error.cgColor)
        ctx.fillEllipse(in: CGRect(x: pill.minX + 3, y: pill.minY + 3, width: size, height: size))
    }

    func drawLeadingIcon(tab: Pane.Tab, theme: TerminalTheme, x: CGFloat, midY: CGFloat, isActive: Bool) -> CGFloat {
        // Content type icon for non-terminal tabs
        if tab.contentType != .terminal {
            let iconColor = isActive ? theme.chromeText : theme.chromeMuted
            guard
                let drawn = Self.drawTabIcon(
                    symbolName: tab.contentType.symbolName, color: iconColor, x: x, midY: midY, isActive: isActive)
            else { return 0 }
            drawn.draw()
            return drawn.width
        }

        // Process icon (when a non-shell process is running) — terminal tabs only.
        // Gated on the same predicate `measuredTabWidth` uses to reserve the space.
        guard tabHasLeadingIcon(tab) else { return 0 }
        let process = tab.state.foregroundProcess
        let iconColor = ProcessIcon.themeColor(for: process, theme: theme, isActive: isActive)
        let iconSize: CGFloat = 12
        let opacity: CGFloat = isActive ? 1.0 : 0.7
        if let customImg = ProcessIcon.customImage(for: process, color: iconColor, size: iconSize) {
            let iconRect = CGRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize)
            customImg.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: opacity)
            return Self.tabIconAdvance
        }
        if let iconName = ProcessIcon.icon(for: process),
            let drawn = Self.drawTabIcon(symbolName: iconName, color: iconColor, x: x, midY: midY, isActive: isActive)
        {
            drawn.draw()
            return drawn.width
        }
        return 0
    }

    func drawPlusButton(ctx: CGContext, theme: TerminalTheme, x: CGFloat, y: CGFloat, width: CGFloat, rowH: CGFloat) {
        // Pill button matching the workspace bar's `+` — inset inside its zone so
        // the gap to the last tab pill matches the gap between tab pills.
        let pillRect = Self.tabPillRect(inSlot: CGRect(x: x, y: y, width: width, height: rowH))
        WorkspacePillStyle.fill(
            ctx, rect: pillRect, active: false, hovered: isPlusButtonHovered,
            wsColor: nil, neutral: theme.chromeMuted)

        // "+" centered — adjust for descender so the visible glyph is vertically centered
        let font = TabFonts.plus15Light
        let color = theme.chromeMuted.withAlphaComponent(isPlusButtonHovered ? 0.9 : 0.6)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let plusStr = "+" as NSString
        let plusSize = plusStr.size(withAttributes: attrs)
        let midY = y + rowH / 2
        // In flipped view, draw(at:) y is top of text box. Text box = ascender + descender.
        // Visual center of "+" is at ascender/2 from top. We want that at midY.
        let drawY = midY - font.ascender / 2 - 4
        plusStr.draw(
            at: NSPoint(x: pillRect.midX - plusSize.width / 2, y: drawY),
            withAttributes: attrs)
    }

    // MARK: - Tab Display Helpers

    static func tabDisplayTitle(tab: Pane.Tab) -> String {
        // Non-terminal tabs: use stored title
        if tab.contentType != .terminal {
            return tab.title
        }

        let process = tab.state.foregroundProcess

        // Show process name when a non-shell process is running,
        // but NOT for remote sessions — show host:path instead.
        if !process.isEmpty, !ProcessIcon.isShell(process), tab.remoteSession == nil {
            let displayName = ProcessIcon.displayName(for: process) ?? process
            return displayName
        }

        if let session = tab.remoteSession {
            let path: String
            if let remoteCwd = tab.remoteWorkingDirectory, !remoteCwd.isEmpty {
                path = tildeContractRemotePath(remoteCwd, tab: tab)
            } else if let colonIdx = tab.title.firstIndex(of: ":") {
                let extracted = String(tab.title[tab.title.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                path = extracted.isEmpty ? "~" : extracted
            } else {
                path = "~"
            }
            // Format: "host:path" for SSH/mosh, "tool:target:path" for containers
            let host = session.displayName
            return "\(host):\(path)"
        }
        // Local tab: show tilde-contracted CWD
        let dir = tab.workingDirectory
        if !dir.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if dir == home {
                return "~"
            } else if dir.hasPrefix(home + "/") {
                return "~" + dir.dropFirst(home.count)
            }
            return dir
        }
        return "shell"
    }

    static func tildeContractRemotePath(_ path: String, tab: Pane.Tab) -> String {
        Boo.tildeContractRemotePath(path, session: tab.remoteSession, title: tab.title)
    }

    static func environmentIndicator(for session: RemoteSessionType?) -> (NSColor, String) {
        guard let session = session else {
            return (.booLocal, "")
        }
        switch session {
        case .ssh, .mosh:
            return (.booRemote, "")
        case .container:
            return (.booDocker, "")
        }
    }

    // MARK: - Icon Drawing Helper

    /// Result of preparing a tab icon for drawing.
    struct TabIconDraw {
        let image: NSImage
        let rect: CGRect
        let opacity: CGFloat
        let width: CGFloat

        func draw() {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
        }
    }

    /// Prepare a tinted SF Symbol icon for drawing in the tab bar.
    static func drawTabIcon(
        symbolName: String, color: NSColor, x: CGFloat, midY: CGFloat, isActive: Bool
    ) -> TabIconDraw? {
        guard let iconImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let configured = iconImage.withSymbolConfiguration(config) ?? iconImage
        let iconSize: CGFloat = 12
        let iconRect = CGRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize)

        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: configured.size)
        configured.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        imageRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        return TabIconDraw(
            image: tinted,
            rect: iconRect,
            opacity: isActive ? 1.0 : 0.7,
            width: PaneView.tabIconAdvance
        )
    }

    // MARK: - New Tab Menu

    /// Show dropdown menu for creating new tabs of different types.
    func showNewTabMenu(event: NSEvent) {
        let menu = NSMenu()
        for type in ContentType.creatableTypes {
            let item = NSMenuItem(
                title: "New \(type.displayName) Tab",
                action: #selector(newTabMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = type.icon
            item.representedObject = type
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func newTabMenuAction(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType else { return }
        addNewTab(contentType: type, workingDirectory: pane.activeTab?.workingDirectory ?? "~", group: activeGroupID)
    }
}
