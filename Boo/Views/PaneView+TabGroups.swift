import Cocoa

extension PaneView {
    // MARK: - Tab Groups

    private static let groupChipPadX: CGFloat = 10
    private static let groupDotSize: CGFloat = 7
    private static let groupDotGap: CGFloat = 6

    /// The chip's text. A crew's starts with the agent glyph and, collapsed,
    /// ends with its most urgent state ("✦ boo · 1 waiting").
    func groupLabel(_ group: TabGroup) -> String {
        guard group.isCrew else { return group.name }
        let name = "\u{2726} " + group.name
        guard group.isCollapsed, let state = crewSummary(group) else { return name }
        return "\(name) · \(state)"
    }

    private func crewItems(_ group: TabGroup) -> [AgentInbox.Item] {
        pane.tabIndices(inGroup: group.id).compactMap { AgentInbox.shared.items[pane.tabs[$0].id] }
    }

    /// The crew's most urgent agent (waiting beats failed beats working beats
    /// done) and how many share its state.
    private func crewTop(_ group: TabGroup) -> (item: AgentInbox.Item, count: Int)? {
        let rank: [AgentInbox.State: Int] = [.needsInput: 0, .error: 1, .working: 2, .done: 3]
        let items = crewItems(group)
        guard let top = items.min(by: { rank[$0.state, default: 4] < rank[$1.state, default: 4] }) else { return nil }
        return (top, items.filter { $0.state == top.state }.count)
    }

    /// "1 waiting", "2 working", or "done" once every agent is.
    func crewSummary(_ group: TabGroup) -> String? {
        guard let (top, count) = crewTop(group) else { return nil }
        let word: String? =
            switch top.state {
            case .needsInput: "waiting"
            case .error: "failed"
            case .working: "working"
            case .done: nil
            }
        return word.map { "\(count) \($0)" } ?? "done"
    }

    /// The dot's color: the group color, or for a crew its most urgent state's.
    func groupDotColor(_ group: TabGroup, theme: TerminalTheme) -> NSColor {
        guard group.isCrew, let top = crewTop(group)?.item else { return groupTint(group, theme: theme) }
        return AgentInboxSegment.color(for: top, theme: theme)
    }

    /// Chip content: a dot and the name while expanded; the name and a tab
    /// count badge while collapsed. An unnamed group drops the name.
    private func groupChipContentWidth(_ group: TabGroup) -> CGFloat {
        let label = groupLabel(group)
        let nameW =
            label.isEmpty
            ? 0 : ceil((label as NSString).size(withAttributes: [.font: TabFonts.groupChip]).width)
        if group.isCollapsed {
            return (nameW > 0 ? nameW + Self.groupDotGap : 0) + groupBadgeWidth(group)
        }
        return Self.groupDotSize + (nameW > 0 ? Self.groupDotGap + nameW : 0)
    }

    private func groupBadgeWidth(_ group: TabGroup) -> CGFloat {
        let count = "\(pane.tabIndices(inGroup: group.id).count)" as NSString
        return max(16, ceil(count.size(withAttributes: [.font: TabFonts.groupBadge]).width) + 10)
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

        let labelText = groupLabel(group)
        var cx = pill.minX + Self.groupChipPadX
        if !group.isCollapsed {
            if labelText.isEmpty { cx = pill.midX - Self.groupDotSize / 2 }
            ctx.setFillColor(groupDotColor(group, theme: theme).cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: cx, y: pill.midY - Self.groupDotSize / 2, width: Self.groupDotSize, height: Self.groupDotSize))
            cx += Self.groupDotSize + Self.groupDotGap
        }
        let badgeW = group.isCollapsed ? groupBadgeWidth(group) : 0
        if !group.isCollapsed || !labelText.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: TabFonts.groupChip, .foregroundColor: text, .paragraphStyle: para
            ]
            let label = labelText as NSString
            let size = label.size(withAttributes: attrs)
            let room = pill.maxX - Self.groupChipPadX - cx - (badgeW > 0 ? badgeW + Self.groupDotGap : 0)
            label.draw(
                in: CGRect(
                    x: cx, y: pill.midY - size.height / 2, width: max(0, min(size.width, room)), height: size.height),
                withAttributes: attrs)
        }
        if badgeW > 0 {
            let badge = CGRect(
                x: labelText.isEmpty ? pill.midX - badgeW / 2 : pill.maxX - Self.groupChipPadX - badgeW,
                y: pill.midY - 8, width: badgeW, height: 16)
            ctx.setFillColor(text.withAlphaComponent(0.2).cgColor)
            WorkspacePillStyle.fillRoundedRect(ctx, rect: badge, radius: 8)
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
}
