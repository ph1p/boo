import Cocoa

// MARK: - Group Headers

extension WorkspaceBarView {
    /// Frame of a group header in view coordinates (scroll applied).
    func groupHeaderRect(_ header: GroupHeader) -> CGRect {
        CGRect(
            x: verticalPillX, y: header.top - verticalScrollOffset, width: verticalPillWidth,
            height: header.height)
    }

    /// Frame of a group's tray in view coordinates (scroll applied).
    func groupTrayRect(_ header: GroupHeader) -> CGRect {
        let pad = WorkspacePillStyle.groupTrayPadding
        return CGRect(
            x: verticalPillX - pad, y: header.top - pad - verticalScrollOffset,
            width: verticalPillWidth + pad * 2, height: header.trayHeight)
    }

    func hitTestGroupHeader(at point: NSPoint) -> GroupHeader? {
        if verticalPlusRect.contains(point) || point.y > verticalScrollViewportHeight { return nil }
        for header in groupHeaders {
            let r = groupHeaderRect(header)
            let strip = CGRect(x: verticalStripX, y: r.minY, width: Self.verticalWidth, height: r.height)
            if strip.contains(point) { return header }
        }
        return nil
    }

    /// Trays plus header rows (or collapsed folders), drawn under the pills.
    func drawGroupHeaders(_ ctx: CGContext, theme: TerminalTheme) {
        for header in groupHeaders {
            let tray = groupTrayRect(header)
            if tray.maxY < 0 || tray.minY > verticalScrollViewportHeight { continue }
            let rect = groupHeaderRect(header)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            if isDragging && draggedGroupID == header.id { ctx.setAlpha(0.3) }
            let highlighted =
                dropGroupID == header.id || dropStackIndex.map { header.members.contains($0) } == true
            WorkspacePillStyle.drawGroupTray(
                ctx, rect: tray, color: header.color, highlighted: highlighted, theme: theme)
            let hovered = hoveredGroupID == header.id
            let tint = WorkspacePillStyle.groupTint(color: header.color, hovered: hovered, theme: theme)
            if header.collapsed {
                drawCollapsedGroup(ctx, header, in: rect, tint: tint, hovered: hovered, theme: theme)
            } else {
                drawGroupHeaderRow(ctx, header, in: rect, tint: tint, hovered: hovered, theme: theme)
            }
        }
    }

    /// Expanded group: chevron plus the first letters of the name, centred in the row.
    private func drawGroupHeaderRow(
        _ ctx: CGContext, _ header: GroupHeader, in rect: CGRect, tint: NSColor, hovered: Bool,
        theme: TerminalTheme
    ) {
        if hovered {
            WorkspacePillStyle.fillGroupHeaderHover(ctx, rect: rect, radius: rect.height / 2, theme: theme)
        }
        let chevron: CGFloat = 7
        let gap: CGFloat = 3
        let label = String(header.name.prefix(3)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.groupLabelFont, .foregroundColor: tint]
        let size = label.size(withAttributes: attrs)
        let textW = min(size.width, rect.width - chevron - gap - 4)
        let x = rect.midX - (chevron + gap + textW) / 2
        WorkspacePillStyle.drawGroupChevron(
            collapsed: false, in: CGRect(x: x, y: rect.midY - chevron / 2, width: chevron, height: chevron),
            color: tint)
        label.draw(
            in: CGRect(x: x + chevron + gap, y: rect.midY - size.height / 2, width: textW, height: size.height),
            withAttributes: attrs)
    }

    /// Collapsed group: a folder pill with the group's initials and a member-count badge.
    private func drawCollapsedGroup(
        _ ctx: CGContext, _ header: GroupHeader, in rect: CGRect, tint: NSColor, hovered: Bool,
        theme: TerminalTheme
    ) {
        WorkspacePillStyle.fill(
            ctx, rect: rect, active: false, hovered: hovered, wsColor: header.color, neutral: theme.chromeMuted)
        let label = String(header.name.prefix(2)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.pillLabelRegular, .foregroundColor: tint]
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 3), withAttributes: attrs)

        WorkspacePillStyle.drawGroupCountBadge(
            ctx, count: header.members.count, center: CGPoint(x: rect.midX, y: rect.maxY - 9), height: 12,
            font: Self.groupCountFont, hiddenActivity: header.hiddenActivity, theme: theme, tint: header.color)
        WorkspacePillStyle.drawStatus(
            ctx, rect: rect, hasActivity: header.hiddenActivity, progress: nil, theme: theme, inset: 4)
    }
}
