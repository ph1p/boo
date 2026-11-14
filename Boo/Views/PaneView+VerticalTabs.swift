import Cocoa

/// Vertical tabs: the pane's tabs as a list in a column on its left instead of
/// a bar on top. Each tab is a two-line row (title, then agent status or the
/// folder of a running program); a group opens with a header row holding its
/// chip. The `+` / ⋯ / unzoom footer follows the last row and sticks to the
/// column's bottom once the rows overflow and scroll above it.
///
/// Geometry reuses the bar's slot model: `tabSlotRect` returns a row (header
/// included for a group's first tab), so hit-testing, hover, drag and the
/// context menu run through the same code as the horizontal modes.
extension PaneView {

    enum VerticalFonts {
        nonisolated(unsafe) static let title = NSFont.systemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let titleActive = NSFont.systemFont(ofSize: 11, weight: .medium)
        nonisolated(unsafe) static let detail = NSFont.systemFont(ofSize: 10, weight: .regular)
        nonisolated(unsafe) static let groupName = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        nonisolated(unsafe) static let groupCount = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    }

    static let verticalTabColumnMaxWidth: CGFloat = 168
    /// Row of a tab with only a title.
    static let verticalTabRowHeight: CGFloat = 36
    /// Row of a tab with a second (status / folder) line.
    static let verticalTabDetailRowHeight: CGFloat = 46
    static let verticalGroupHeaderHeight: CGFloat = 24
    /// Footer row holding `+` / ⋯ / unzoom.
    static let verticalFooterHeight: CGFloat = 32
    /// Above the first row, so its pill sits 8pt below the pane's top edge.
    static let verticalTopInset: CGFloat = 6
    /// Between the last row and the footer.
    static let verticalFooterGap: CGFloat = 2

    var isVerticalTabs: Bool { tabOverflowMode == .vertical }

    /// Width of the tab column; 0 outside vertical mode. Narrow panes give up
    /// at most 40% of their width to it.
    var verticalTabColumnWidth: CGFloat {
        guard isVerticalTabs else { return 0 }
        return min(Self.verticalTabColumnMaxWidth, (bounds.width * 0.4).rounded())
    }

    /// The area holding the tabs: the top bar, or the left column.
    var tabBarRect: CGRect {
        if isVerticalTabs { return CGRect(x: 0, y: 0, width: verticalTabColumnWidth, height: bounds.height) }
        return CGRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight)
    }

    func isInTabBar(_ point: NSPoint) -> Bool { tabBarRect.contains(point) }

    /// Row height per tab: its group's header for a group's first tab, plus
    /// the tab row unless the group is collapsed. Rows with a second line
    /// are taller so neither line crowds the pill's edges.
    func verticalSlotHeights() -> [CGFloat] {
        pane.tabs.indices.map { i in
            let header = pane.isFirstTabOfGroup(at: i) ? Self.verticalGroupHeaderHeight : 0
            guard !pane.isTabHidden(at: i) else { return header }
            return header
                + (hasVerticalTabDetail(pane.tabs[i]) ? Self.verticalTabDetailRowHeight : Self.verticalTabRowHeight)
        }
    }

    func verticalSlotRect(at index: Int, heights: [CGFloat]? = nil) -> CGRect? {
        let h = heights ?? verticalSlotHeights()
        guard index < h.count else { return nil }
        let y = Self.verticalTopInset + h.prefix(index).reduce(0, +) - tabScrollOffset
        return CGRect(x: Self.tabBarSideInset, y: y, width: verticalRowWidth, height: h[index])
    }

    /// Width of a row or the footer; `- 1` keeps the pills clear of the
    /// column's divider.
    var verticalRowWidth: CGFloat { verticalTabColumnWidth - Self.tabBarSideInset * 2 - 1 }

    /// Where the footer starts below the rows, before scrolling.
    func verticalRowsEnd(heights: [CGFloat]? = nil) -> CGFloat {
        Self.verticalTopInset + (heights ?? verticalSlotHeights()).reduce(0, +) + Self.verticalFooterGap
    }

    /// Tab row of a slot, below its group header.
    func verticalRowRect(inSlot slot: CGRect, index: Int) -> CGRect {
        let header = pane.isFirstTabOfGroup(at: index) ? Self.verticalGroupHeaderHeight : 0
        return CGRect(x: slot.minX, y: slot.minY + header, width: slot.width, height: slot.height - header)
    }

    func verticalPillRect(inRow row: CGRect) -> CGRect {
        row.insetBy(dx: Self.tabPillInsetX, dy: 2)
    }

    /// Top of the footer when it sticks to the column's bottom; the rows
    /// scroll above this line once they overflow.
    var verticalPinnedFooterY: CGFloat {
        bounds.height - Self.verticalFooterHeight - Self.tabBarSideInset
    }

    /// The `+` / ⋯ / unzoom footer: right under the last row, or pinned to
    /// the bottom when the rows don't fit.
    func verticalFooterSlot(heights: [CGFloat]? = nil) -> CGRect {
        let y = min(verticalRowsEnd(heights: heights) - tabScrollOffset, verticalPinnedFooterY)
        return CGRect(
            x: Self.tabBarSideInset, y: y, width: verticalRowWidth, height: Self.verticalFooterHeight)
    }

    func verticalScrollMaxOffset(heights: [CGFloat]? = nil) -> CGFloat {
        max(0, verticalRowsEnd(heights: heights) - verticalPinnedFooterY)
    }

    func verticalTabIndex(at point: NSPoint) -> Int? {
        guard point.x < verticalTabColumnWidth else { return nil }
        let heights = verticalSlotHeights()
        guard point.y < verticalFooterSlot(heights: heights).minY else { return nil }
        for i in heights.indices {
            guard let slot = verticalSlotRect(at: i, heights: heights), slot.height > 0 else { continue }
            if point.y >= slot.minY && point.y < slot.maxY { return i }
        }
        return nil
    }

    /// Insertion index for a drop at `point`: before the first visible row
    /// whose middle is below the cursor.
    func verticalInsertionIndex(at point: NSPoint) -> Int {
        let heights = verticalSlotHeights()
        for i in heights.indices where !pane.isTabHidden(at: i) {
            guard let slot = verticalSlotRect(at: i, heights: heights) else { continue }
            if point.y < verticalRowRect(inSlot: slot, index: i).midY { return i }
        }
        return pane.tabs.count
    }

    /// Flipped y of the gap a drop at `index` goes into.
    func verticalInsertionY(at index: Int) -> CGFloat {
        let heights = verticalSlotHeights()
        if index < heights.count, let slot = verticalSlotRect(at: index, heights: heights) { return slot.minY }
        if let last = verticalSlotRect(at: heights.count - 1, heights: heights) { return last.maxY }
        return Self.verticalTopInset
    }

    func autoscrollVerticalTabs(localY: CGFloat) {
        let maxScroll = verticalScrollMaxOffset()
        guard maxScroll > 0 else { return }
        let edgeZone: CGFloat = 32
        let step: CGFloat = 8
        if localY < edgeZone {
            tabScrollOffset = max(0, tabScrollOffset - step)
            needsDisplay = true
        } else if localY > verticalPinnedFooterY - edgeZone {
            tabScrollOffset = min(maxScroll, tabScrollOffset + step)
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    func drawTabsVertical(ctx: CGContext, theme: TerminalTheme) {
        let colW = verticalTabColumnWidth
        guard colW > 0 else { return }
        ctx.setFillColor(theme.background.nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: colW, height: bounds.height))
        ctx.setFillColor(theme.paneBorder.cgColor)
        ctx.fill(CGRect(x: colW - 1, y: 0, width: 1, height: bounds.height))

        let heights = verticalSlotHeights()
        let pinnedY = verticalPinnedFooterY
        let maxScroll = verticalScrollMaxOffset(heights: heights)
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        // Keep the active row in view when the active tab changes.
        if pane.activeTabIndex != lastAutoScrolledTabIndex,
            let slot = verticalSlotRect(at: pane.activeTabIndex, heights: heights)
        {
            lastAutoScrolledTabIndex = pane.activeTabIndex
            if slot.minY < Self.verticalTopInset {
                tabScrollOffset += slot.minY - Self.verticalTopInset
            } else if slot.maxY > pinnedY {
                tabScrollOffset += slot.maxY - pinnedY
            }
            tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        }
        let footer = verticalFooterSlot(heights: heights)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: colW - 1, height: footer.minY))
        drawVerticalGroupContainers(ctx: ctx, theme: theme, heights: heights)
        for (i, tab) in pane.tabs.enumerated() {
            guard let slot = verticalSlotRect(at: i, heights: heights), slot.height > 0,
                slot.maxY > 0, slot.minY < footer.minY
            else { continue }
            if pane.isFirstTabOfGroup(at: i), let group = pane.group(id: tab.groupID) {
                drawVerticalGroupHeader(
                    ctx: ctx, theme: theme, group: group,
                    header: CGRect(
                        x: slot.minX, y: slot.minY, width: slot.width, height: Self.verticalGroupHeaderHeight),
                    hovered: hoveredTabIndex == i && isGroupChipHovered)
            }
            guard !pane.isTabHidden(at: i) else { continue }
            let slide = tabSlideOffset(for: tab.id)
            drawVerticalTab(
                ctx: ctx, theme: theme, tab: tab, index: i,
                row: verticalRowRect(inSlot: slot, index: i).offsetBy(dx: slide.x, dy: slide.y),
                isActive: i == pane.activeTabIndex)
        }
        if tabScrollOffset < maxScroll {
            WorkspacePillStyle.drawFade(
                ctx, in: CGRect(x: 0, y: footer.minY - 24, width: colW - 1, height: 24),
                from: CGPoint(x: 0, y: footer.minY), to: CGPoint(x: 0, y: footer.minY - 24),
                color: theme.background.nsColor)
        }
        drawGroupDropIndicator(ctx: ctx, theme: theme)
        ctx.restoreGState()

        drawTabBarButtons(ctx: ctx, theme: theme, cluster: footer)
    }

    /// Tinted backdrop spanning an expanded group's header and rows.
    private func drawVerticalGroupContainers(ctx: CGContext, theme: TerminalTheme, heights: [CGFloat]) {
        for group in pane.groups where !group.isCollapsed {
            let members = pane.tabIndices(inGroup: group.id)
            guard let first = members.first, let last = members.last,
                let top = verticalSlotRect(at: first, heights: heights),
                let bottom = verticalSlotRect(at: last, heights: heights)
            else { continue }
            let rect = CGRect(x: top.minX + 1, y: top.minY, width: top.width - 2, height: bottom.maxY - top.minY)
            drawGroupBackdrop(
                ctx, rect: rect, tint: groupTint(group, theme: theme),
                faded: groupDropIndex != nil && groupPressID == group.id)
        }
    }

    func verticalGroupHeaderPill(_ header: CGRect) -> CGRect {
        header.insetBy(dx: Self.tabPillInsetX + 1, dy: 3)
    }

    /// Group header row: dot, name, muted tab count, and a disclosure chevron.
    /// Collapsed, it fills with the group color like the horizontal chip.
    private func drawVerticalGroupHeader(
        ctx: CGContext, theme: TerminalTheme, group: TabGroup, header: CGRect, hovered: Bool
    ) {
        let pill = verticalGroupHeaderPill(header)
        let tint = groupTint(group, theme: theme)
        let text: NSColor
        if group.isCollapsed {
            ctx.setFillColor(tint.withAlphaComponent(hovered ? 1 : 0.85).cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: pill)
            text = Self.contrastingText(on: tint)
        } else {
            if hovered {
                ctx.setFillColor(tint.withAlphaComponent(0.18).cgColor)
                WorkspacePillStyle.fillRoundedRect(ctx, rect: pill)
            }
            text = theme.chromeText
        }
        // Lines the name up with the tab titles below it.
        var x = pill.minX + 11
        if !group.isCollapsed {
            ctx.setFillColor(groupDotColor(group, theme: theme).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: pill.midY - 3, width: 6, height: 6))
            x += 11
        }
        let chevron = (group.isCollapsed ? "\u{25B8}" : "\u{25BE}") as NSString
        let mutedAttrs: [NSAttributedString.Key: Any] = [
            .font: VerticalFonts.groupCount, .foregroundColor: text.withAlphaComponent(0.6)
        ]
        let chevronSize = chevron.size(withAttributes: mutedAttrs)
        let chevronX = pill.maxX - 7 - chevronSize.width
        chevron.draw(at: NSPoint(x: chevronX, y: pill.midY - chevronSize.height / 2), withAttributes: mutedAttrs)

        let count = "\(pane.tabIndices(inGroup: group.id).count)" as NSString
        let countSize = count.size(withAttributes: mutedAttrs)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: VerticalFonts.groupName, .foregroundColor: text, .paragraphStyle: para
        ]
        let label = groupLabel(group)
        let name = (label.isEmpty ? "Group" : label) as NSString
        let nameSize = name.size(withAttributes: nameAttrs)
        let nameW = max(0, min(nameSize.width, chevronX - 6 - countSize.width - 5 - x))
        name.draw(
            in: CGRect(x: x, y: pill.midY - nameSize.height / 2, width: nameW, height: nameSize.height),
            withAttributes: nameAttrs)
        count.draw(
            at: NSPoint(x: x + nameW + 5, y: pill.midY - countSize.height / 2), withAttributes: mutedAttrs)
    }

    /// Second line of a row: agent status, else the folder of a running program.
    /// The footer's `+` reads as a row: glyph in the tabs' icon column,
    /// "New Tab" in their title column, so it doesn't float in a wide slot.
    func drawNewTabRow(ctx: CGContext, pill: CGRect, color: NSColor) {
        let tile = Self.iconTileRect(pillMinX: pill.minX, midY: pill.midY)
        WorkspacePillStyle.drawPlusGlyph(ctx, in: tile, halfSpan: 4.5, color: color)
        let attrs: [NSAttributedString.Key: Any] = [.font: VerticalFonts.title, .foregroundColor: color]
        let label = "New Tab" as NSString
        let size = label.size(withAttributes: attrs)
        let x = pill.minX + Self.tabTextLeadIn + Self.tabIconAdvance
        guard x + size.width <= pill.maxX - 4 else { return }
        label.draw(at: NSPoint(x: x, y: pill.midY - size.height / 2), withAttributes: attrs)
    }

    /// Whether `verticalTabDetail` has a line for `tab`, without building it;
    /// row heights ask this on every pointer move.
    func hasVerticalTabDetail(_ tab: Pane.Tab) -> Bool {
        if AgentInbox.shared.items[tab.id] != nil { return true }
        let process = tab.state.foregroundProcess
        return tab.contentType == .terminal && !process.isEmpty && !ProcessIcon.isShell(process)
            && !tab.workingDirectory.isEmpty
    }

    func verticalTabDetail(_ tab: Pane.Tab) -> (text: String, dot: NSColor?)? {
        guard hasVerticalTabDetail(tab) else { return nil }
        if let item = AgentInbox.shared.items[tab.id] {
            let status: String
            switch item.state {
            case .needsInput: status = "Needs input"
            case .working: status = item.tool.map { "Working · \($0)" } ?? "Working"
            case .done: status = "Done"
            case .error: status = "Error"
            }
            return (status, AgentInboxSegment.color(for: item, theme: booTheme))
        }
        return ((tab.workingDirectory as NSString).lastPathComponent, nil)
    }

    private func drawVerticalTab(
        ctx: CGContext, theme: TerminalTheme, tab: Pane.Tab, index: Int, row: CGRect, isActive: Bool
    ) {
        let isHovered = hoveredTabIndex == index && !isGroupChipHovered
        let pill = verticalPillRect(inRow: row)
        // Tabs of a group being dragged fade so the drop indicator reads clearly.
        let inFlight = tab.groupID != nil && groupDropIndex != nil && groupPressID == tab.groupID
        if inFlight {
            ctx.saveGState()
            ctx.setAlpha(0.45)
        }
        defer { if inFlight { ctx.restoreGState() } }
        WorkspacePillStyle.fill(
            ctx, rect: pill, active: isActive, hovered: isHovered, wsColor: nil, neutral: theme.chromeMuted)
        if selectedTabIDs.contains(tab.id) {
            WorkspacePillStyle.strokeHairline(ctx, rect: pill, color: theme.accentColor)
        }

        let showClose = showTabClose && (isActive || isHovered)
        let closeZone: CGFloat = showClose ? 26 : 10
        let detail = verticalTabDetail(tab)
        let titleMidY = detail == nil ? pill.midY : pill.minY + 14
        var textX = pill.minX + Self.tabTextLeadIn
        // The icon centers on the row, so a two-line row reads as one item.
        textX += drawLeadingIcon(tab: tab, theme: theme, x: textX, midY: pill.midY, isActive: isActive)
        let maxW = max(0, pill.maxX - textX - closeZone)

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: isActive ? VerticalFonts.titleActive : VerticalFonts.title,
            .foregroundColor: isActive
                ? theme.chromeText : (isHovered ? theme.chromeText.withAlphaComponent(0.8) : theme.chromeMuted),
            .paragraphStyle: para
        ]
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        let badge = ProfileBadge.text(for: tab)
        let badgeW = badge.map { ProfileBadge.width(of: $0) + ProfileBadge.gap } ?? 0
        let titleW = min(titleSize.width, max(0, maxW - badgeW))
        title.draw(
            in: CGRect(x: textX, y: titleMidY - titleSize.height / 2, width: titleW, height: titleSize.height),
            withAttributes: titleAttrs)
        if let badge, maxW > badgeW {
            ProfileBadge.draw(
                ctx, text: badge, x: textX + titleW + ProfileBadge.gap, midY: titleMidY,
                color: tab.state.profile.flatMap { ProfileStore.shared.accent(forProfile: $0) } ?? theme.accentColor)
        }

        if let detail {
            var x = textX
            let midY = pill.minY + 28
            if let dot = detail.dot {
                ctx.setFillColor(dot.cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: midY - 3, width: 6, height: 6))
                x += 10
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: VerticalFonts.detail, .foregroundColor: theme.chromeMuted, .paragraphStyle: para
            ]
            let text = detail.text as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(
                in: CGRect(
                    x: x, y: midY - size.height / 2, width: min(size.width, max(0, pill.maxX - x - closeZone)),
                    height: size.height),
                withAttributes: attrs)
        }

        if let progress = tab.state.progress {
            let bar = CGRect(
                x: pill.minX + 6, y: pill.maxY - ProgressBarStyle.height - 1, width: pill.width - 12,
                height: ProgressBarStyle.height)
            ProgressBarStyle.draw(ctx, progress: progress, in: bar, theme: theme)
        } else if let name = tab.state.profile, let accent = ProfileStore.shared.accent(forProfile: name) {
            // Profile accent along the pill's leading edge.
            ctx.setFillColor(accent.cgColor)
            let bar = CGRect(x: pill.minX + 2, y: pill.minY + 6, width: 2, height: pill.height - 12)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath()
        }

        if tab.state.isRecording { Self.drawRecordingDot(ctx, in: pill, theme: booTheme) }

        if tab.state.hasActivity && !isActive {
            let dotSize: CGFloat = 5
            ctx.setFillColor((tab.state.triggerMark != nil ? theme.warning : theme.accentEmphasis).cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: pill.maxX - closeZone - dotSize - 2, y: pill.midY - dotSize / 2, width: dotSize,
                    height: dotSize))
        }

        if showClose {
            let size = WorkspacePillStyle.closeButtonSize
            WorkspacePillStyle.drawCloseButton(
                ctx,
                in: CGRect(
                    x: pill.maxX - size - Self.tabCloseTrailingGap, y: pill.midY - size / 2, width: size,
                    height: size),
                tint: theme.chromeMuted, hovered: isHovered && isCloseButtonHovered)
        }
    }

    /// Close circle of a vertical row, centered on its right edge.
    func isOverVerticalCloseButton(point: NSPoint, tabIndex idx: Int) -> Bool {
        guard let slot = verticalSlotRect(at: idx) else { return false }
        let pill = verticalPillRect(inRow: verticalRowRect(inSlot: slot, index: idx))
        return pill.contains(point) && point.x > pill.maxX - Self.tabCloseHitZone + Self.tabPillInsetX
    }
}
