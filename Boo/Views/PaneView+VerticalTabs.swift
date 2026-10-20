import Cocoa

/// Vertical tabs: the pane's tabs as a list in a column on its left instead of
/// a bar on top. Each tab is a two-line row (title, then agent status or the
/// folder of a running program); a group opens with a header row holding its
/// chip. The `+` pins to the column's bottom and the rows scroll above it.
///
/// Geometry reuses the bar's slot model: `tabSlotRect` returns a row (header
/// included for a group's first tab), so hit-testing, hover, drag and the
/// context menu run through the same code as the horizontal modes.
extension PaneView {

    private enum VerticalFonts {
        nonisolated(unsafe) static let title = NSFont.systemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let titleActive = NSFont.systemFont(ofSize: 11, weight: .medium)
        nonisolated(unsafe) static let detail = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        nonisolated(unsafe) static let close = NSFont.systemFont(ofSize: 8, weight: .bold)
    }

    static let verticalTabColumnMaxWidth: CGFloat = 168
    static let verticalTabRowHeight: CGFloat = 36
    static let verticalGroupHeaderHeight: CGFloat = 24
    static let verticalPlusHeight: CGFloat = 28

    var isVerticalTabs: Bool { AppSettings.shared.tabOverflowMode == .vertical }

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
    /// the tab row unless the group is collapsed.
    func verticalSlotHeights() -> [CGFloat] {
        pane.tabs.indices.map { i in
            (pane.isFirstTabOfGroup(at: i) ? Self.verticalGroupHeaderHeight : 0)
                + (pane.isTabHidden(at: i) ? 0 : Self.verticalTabRowHeight)
        }
    }

    func verticalSlotRect(at index: Int, heights: [CGFloat]? = nil) -> CGRect? {
        let h = heights ?? verticalSlotHeights()
        guard index < h.count else { return nil }
        let inset = Self.tabBarSideInset
        let y = inset + h.prefix(index).reduce(0, +) - tabScrollOffset
        return CGRect(x: inset, y: y, width: verticalTabColumnWidth - inset * 2, height: h[index])
    }

    /// Tab row of a slot, below its group header.
    func verticalRowRect(inSlot slot: CGRect, index: Int) -> CGRect {
        let header = pane.isFirstTabOfGroup(at: index) ? Self.verticalGroupHeaderHeight : 0
        return CGRect(x: slot.minX, y: slot.minY + header, width: slot.width, height: slot.height - header)
    }

    func verticalPillRect(inRow row: CGRect) -> CGRect {
        row.insetBy(dx: Self.tabPillInsetX, dy: 2)
    }

    var verticalPlusSlot: CGRect {
        let inset = Self.tabBarSideInset
        return CGRect(
            x: inset, y: bounds.height - Self.verticalPlusHeight - inset,
            width: verticalTabColumnWidth - inset * 2, height: Self.verticalPlusHeight)
    }

    func verticalScrollMaxOffset(heights: [CGFloat]? = nil) -> CGFloat {
        let total = Self.tabBarSideInset + (heights ?? verticalSlotHeights()).reduce(0, +)
        return max(0, total - verticalPlusSlot.minY)
    }

    func verticalTabIndex(at point: NSPoint) -> Int? {
        guard point.x < verticalTabColumnWidth, point.y < verticalPlusSlot.minY else { return nil }
        let heights = verticalSlotHeights()
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
        return Self.tabBarSideInset
    }

    func autoscrollVerticalTabs(localY: CGFloat) {
        let maxScroll = verticalScrollMaxOffset()
        guard maxScroll > 0 else { return }
        let edgeZone: CGFloat = 32
        let step: CGFloat = 8
        if localY < edgeZone {
            tabScrollOffset = max(0, tabScrollOffset - step)
            needsDisplay = true
        } else if localY > verticalPlusSlot.minY - edgeZone {
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
        let plusSlot = verticalPlusSlot
        let maxScroll = verticalScrollMaxOffset(heights: heights)
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        // Keep the active row in view when the active tab changes.
        if pane.activeTabIndex != lastAutoScrolledTabIndex,
            let slot = verticalSlotRect(at: pane.activeTabIndex, heights: heights)
        {
            lastAutoScrolledTabIndex = pane.activeTabIndex
            if slot.minY < Self.tabBarSideInset {
                tabScrollOffset += slot.minY - Self.tabBarSideInset
            } else if slot.maxY > plusSlot.minY {
                tabScrollOffset += slot.maxY - plusSlot.minY
            }
            tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: colW - 1, height: plusSlot.minY))
        for (i, tab) in pane.tabs.enumerated() {
            guard let slot = verticalSlotRect(at: i, heights: heights), slot.height > 0,
                slot.maxY > 0, slot.minY < plusSlot.minY
            else { continue }
            if pane.isFirstTabOfGroup(at: i), let group = pane.group(id: tab.groupID) {
                drawGroupChip(
                    ctx: ctx, theme: theme, group: group, x: slot.minX, y: slot.minY, width: slot.width,
                    rowH: Self.verticalGroupHeaderHeight, hovered: hoveredTabIndex == i && isGroupChipHovered)
            }
            guard !pane.isTabHidden(at: i) else { continue }
            drawVerticalTab(
                ctx: ctx, theme: theme, tab: tab, index: i, row: verticalRowRect(inSlot: slot, index: i),
                isActive: i == pane.activeTabIndex)
        }
        if tabScrollOffset < maxScroll {
            WorkspacePillStyle.drawFade(
                ctx, in: CGRect(x: 0, y: plusSlot.minY - 24, width: colW - 1, height: 24),
                from: CGPoint(x: 0, y: plusSlot.minY), to: CGPoint(x: 0, y: plusSlot.minY - 24),
                color: theme.background.nsColor)
        }
        ctx.restoreGState()

        drawPlusButton(
            ctx: ctx, theme: theme, x: plusSlot.minX, y: plusSlot.minY, width: plusSlot.width,
            rowH: plusSlot.height)
    }

    /// Second line of a row: agent status, else the folder of a running program.
    func verticalTabDetail(_ tab: Pane.Tab) -> (text: String, dot: NSColor?)? {
        let theme = AppSettings.shared.theme
        if let item = AgentInbox.shared.items[tab.id] {
            let status: String
            switch item.state {
            case .needsInput: status = "Needs input"
            case .working: status = item.tool.map { "Working · \($0)" } ?? "Working"
            case .done: status = "Done"
            case .error: status = "Error"
            }
            return (status, AgentInboxSegment.color(for: item, theme: theme))
        }
        let process = tab.state.foregroundProcess
        guard tab.contentType == .terminal, !process.isEmpty, !ProcessIcon.isShell(process),
            !tab.workingDirectory.isEmpty
        else { return nil }
        return ((tab.workingDirectory as NSString).lastPathComponent, nil)
    }

    private func drawVerticalTab(
        ctx: CGContext, theme: TerminalTheme, tab: Pane.Tab, index: Int, row: CGRect, isActive: Bool
    ) {
        let isHovered = hoveredTabIndex == index && !isGroupChipHovered
        let pill = verticalPillRect(inRow: row)
        WorkspacePillStyle.fill(
            ctx, rect: pill, active: isActive, hovered: isHovered, wsColor: nil, neutral: theme.chromeMuted)
        if let group = pane.group(id: tab.groupID) {
            let color = group.color.nsColor ?? theme.accentColor
            ctx.setFillColor(color.withAlphaComponent(isActive ? 0.9 : 0.6).cgColor)
            ctx.fill(CGRect(x: pill.minX + 2, y: pill.minY + 6, width: 2, height: pill.height - 12))
        }

        let showClose = showTabClose && (isActive || isHovered)
        let closeZone: CGFloat = showClose ? 18 : 8
        let detail = verticalTabDetail(tab)
        let titleMidY = detail == nil ? pill.midY : pill.minY + 11
        var textX = pill.minX + Self.tabTextLeadIn
        textX += drawLeadingIcon(tab: tab, theme: theme, x: textX, midY: titleMidY, isActive: isActive)
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
        title.draw(
            in: CGRect(
                x: textX, y: titleMidY - titleSize.height / 2, width: min(titleSize.width, maxW),
                height: titleSize.height),
            withAttributes: titleAttrs)

        if let detail {
            var x = pill.minX + Self.tabTextLeadIn
            let midY = pill.maxY - 10
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
                    x: x, y: midY - size.height / 2, width: min(size.width, max(0, pill.maxX - x - 8)),
                    height: size.height),
                withAttributes: attrs)
        }

        if let progress = tab.state.progress {
            let bar = CGRect(
                x: pill.minX + 6, y: pill.maxY - ProgressBarStyle.height - 1, width: pill.width - 12,
                height: ProgressBarStyle.height)
            ProgressBarStyle.draw(ctx, progress: progress, in: bar, theme: theme)
        }

        if tab.state.hasActivity && !isActive {
            let dotSize: CGFloat = 5
            ctx.setFillColor(theme.accentEmphasis.cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: pill.maxX - closeZone - dotSize - 2, y: titleMidY - dotSize / 2, width: dotSize,
                    height: dotSize))
        }

        if showClose {
            let closeHovered = isHovered && isCloseButtonHovered
            let size = WorkspacePillStyle.closeButtonSize
            let center = CGPoint(x: pill.maxX - size / 2 - Self.tabCloseTrailingGap, y: titleMidY)
            if closeHovered {
                ctx.setFillColor(theme.controlFill.cgColor)
                ctx.fillEllipse(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: VerticalFonts.close,
                .foregroundColor: theme.chromeMuted.withAlphaComponent(closeHovered ? 0.9 : (isActive ? 0.7 : 0.5))
            ]
            let mark = "\u{2715}" as NSString
            let markSize = mark.size(withAttributes: attrs)
            mark.draw(
                at: NSPoint(x: center.x - markSize.width / 2, y: center.y - markSize.height / 2), withAttributes: attrs)
        }
    }

    /// Close circle of a vertical row, next to the title.
    func isOverVerticalCloseButton(point: NSPoint, tabIndex idx: Int) -> Bool {
        guard let slot = verticalSlotRect(at: idx) else { return false }
        let pill = verticalPillRect(inRow: verticalRowRect(inSlot: slot, index: idx))
        return pill.contains(point) && point.x > pill.maxX - Self.tabCloseHitZone + Self.tabPillInsetX
    }
}
