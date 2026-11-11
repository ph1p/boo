import Cocoa

extension PaneView {

    // MARK: - Font Cache

    enum TabFonts {
        nonisolated(unsafe) static let title10Regular = NSFont.systemFont(ofSize: 12, weight: .medium)
        nonisolated(unsafe) static let title10Medium = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nonisolated(unsafe) static let subtitle = NSFont.systemFont(ofSize: 12, weight: .regular)
        nonisolated(unsafe) static let groupChip = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        nonisolated(unsafe) static let groupBadge = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    }

    // MARK: - Pill Metrics

    /// Horizontal inset of the pill inside its tab slot — two adjacent slots yield
    /// a `2 × tabPillInsetX` gap between pills.
    static let tabPillInsetX: CGFloat = 4
    /// Height of a tab pill, vertically centred in the tab row.
    static let tabPillHeight: CGFloat = 28
    /// Inset of the first/last tab slot from the pane edge. Together with
    /// `tabPillInsetX` the outermost pills sit `tabBarSideInset + tabPillInsetX`
    /// from the pane edge — the same 6pt the pills keep between each other.
    static let tabBarSideInset: CGFloat = 4
    /// Lead-in from the pill's left edge to its first content (icon or title).
    static let tabTextLeadIn: CGFloat = 12
    /// Width a leading icon advances the title by. The icon sits on a tile that
    /// starts `tabIconTileInset` from the pill edge (closer than `tabTextLeadIn`).
    static let tabIconAdvance: CGFloat = 20
    /// Rounded tile behind a tab's leading icon, inset from the pill's left edge
    /// by the same amount as from its top and bottom.
    static let tabIconTileSize: CGFloat = 20
    static let tabIconTileInset: CGFloat = (tabPillHeight - tabIconTileSize) / 2
    /// Trailing gap between the close circle and the pill's right edge.
    static let tabCloseTrailingGap: CGFloat = 6
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
        // When overflowing, the buttons pin in front of the right side inset and
        // the scrollable strip clips just before them.
        let pinnedButtonsX = bounds.width - tabBarButtonsWidth - inset

        // Clamp and auto-scroll to active tab only when active tab changes
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        if isOverflowing && pane.activeTabIndex != lastAutoScrolledTabIndex {
            lastAutoScrolledTabIndex = pane.activeTabIndex
            let activeStart = tabStartX(pane.activeTabIndex, widths: widths) - tabScrollOffset
            let activeEnd = activeStart + widths[pane.activeTabIndex]
            if activeStart < inset {
                tabScrollOffset += activeStart - inset
            } else if activeEnd > pinnedButtonsX {
                tabScrollOffset += activeEnd - pinnedButtonsX
            }
            tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        } else if !isOverflowing {
            tabScrollOffset = 0
        }

        // Clip scrollable tabs so they don't draw over the pinned plus button
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: pinnedButtonsX, height: barH + 1))

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
                    ctx, in: CGRect(x: pinnedButtonsX - fadeW, y: 0, width: fadeW, height: barH),
                    from: CGPoint(x: pinnedButtonsX, y: 0), to: CGPoint(x: pinnedButtonsX - fadeW, y: 0),
                    color: theme.background.nsColor)
            }
        }
        drawGroupDropIndicator(ctx: ctx, theme: theme)

        ctx.restoreGState()

        drawTabBarButtons(ctx: ctx, theme: theme, cluster: tabBarButtonsSlot(widths: widths))
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

        drawTabBarButtons(ctx: ctx, theme: theme, cluster: tabBarButtonsSlot(layouts: layouts))
    }

    /// Rect of the `+` / ⋯ / unzoom buttons in the current overflow mode — the
    /// ONE place that knows where they sit. Draw and hit-test both read it.
    /// Scroll mode: follows the last tab while everything fits, pins in front of
    /// the right side inset once the strip overflows. Wrap mode: after the last
    /// tab, or on a row of its own when they don't fit. Vertical: under the
    /// last tab, sticking to the column's bottom once the tabs overflow.
    func tabBarButtonsSlot(widths: [CGFloat]? = nil) -> CGRect {
        let inset = Self.tabBarSideInset
        if isVerticalTabs { return verticalFooterSlot() }
        let w = widths ?? allTabWidths()
        if AppSettings.shared.tabOverflowMode == .wrap {
            return tabBarButtonsSlot(layouts: wrapLayout(widths: w))
        }
        let isOverflowing = scrollMaxOffset(widths: w) > 0
        let x = isOverflowing ? bounds.width - tabBarButtonsWidth - inset : inset + w.reduce(0, +)
        return CGRect(x: x, y: 0, width: tabBarButtonsWidth, height: tabBarHeight)
    }

    /// Wrap-mode button rect for callers that already computed the layouts.
    func tabBarButtonsSlot(layouts: [TabLayout]) -> CGRect {
        let inset = Self.tabBarSideInset
        let lastLay = layouts.last
        if plusFitsOnLastRow(layouts) {
            return CGRect(
                x: (lastLay?.x ?? inset) + (lastLay?.width ?? 0), y: lastLay?.y ?? inset,
                width: tabBarButtonsWidth, height: singleRowTabHeight)
        }
        return CGRect(
            x: inset, y: (lastLay?.y ?? inset) + singleRowTabHeight,
            width: tabBarButtonsWidth, height: singleRowTabHeight)
    }

    func drawSingleTab(
        ctx: CGContext, theme: TerminalTheme, tab: Pane.Tab, index: Int, x: CGFloat, y: CGFloat,
        width: CGFloat, rowH: CGFloat, isActive: Bool
    ) {
        let slide = tabSlideOffset(for: tab.id)
        var x = x + slide.x
        let y = y + slide.y
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

        // An agent's state badges its icon tile; a tab without one shows it in the
        // close slot, on the active tab too.
        let agentColor = Self.agentBadgeColor(for: AgentInbox.shared.items[tab.id], theme: theme)
        let agentOnTile = agentColor != nil && tabHasLeadingIcon(tab)
        let agentInSlot = agentColor != nil && !agentOnTile
        // Close button visible on hover or active tab (when closeable); an agent
        // badge in the slot gives way to it on hover only.
        let showClose = showTabClose && (isHovered || isActive && !agentInSlot)
        // The activity dot sits in the close slot, so either one reserves it.
        let showDot = (agentInSlot || tab.state.hasActivity && !isActive) && !showClose
        let closeZone: CGFloat =
            (showClose || showDot) ? WorkspacePillStyle.closeButtonSize + Self.tabCloseTrailingGap + 4 : 10

        let iconX = textX
        textX += drawLeadingIcon(tab: tab, theme: theme, x: textX, midY: midY, isActive: isActive)
        if agentOnTile, let agentColor {
            Self.drawAgentBadge(
                ctx, color: agentColor, theme: theme,
                tileCorner: CGPoint(
                    x: iconX - Self.tabTextLeadIn + Self.tabIconTileInset + Self.tabIconTileSize,
                    y: midY - Self.tabIconTileSize / 2))
        }

        // Title — use truncating tail paragraph style for automatic ellipsis
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: isActive ? TabFonts.title10Medium : TabFonts.title10Regular,
            .foregroundColor: isActive
                ? theme.chromeText : (isHovered ? theme.chromeText.withAlphaComponent(0.8) : theme.chromeMuted),
            .paragraphStyle: para
        ]
        let title = NSMutableAttributedString(string: Self.tabDisplayTitle(tab: tab), attributes: attrs)
        if let subtitle = Self.tabDisplaySubtitle(tab: tab) {
            title.append(
                NSAttributedString(
                    string: "  " + subtitle,
                    attributes: [
                        .font: TabFonts.subtitle,
                        .foregroundColor: theme.chromeMuted.withAlphaComponent(isActive ? 0.75 : 0.55),
                        .paragraphStyle: para
                    ]))
        }
        let titleSize = title.size()
        let maxTitleW = max(0, pillRect.maxX - textX - closeZone)
        title.draw(
            in: CGRect(
                x: textX, y: midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW), height: titleSize.height))

        // OSC 9;4 progress along the pill's bottom edge.
        if let progress = tab.state.progress {
            let bar = CGRect(
                x: pillRect.minX + 8, y: pillRect.maxY - ProgressBarStyle.height - 1,
                width: pillRect.width - 16, height: ProgressBarStyle.height)
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

        let closeSize = WorkspacePillStyle.closeButtonSize
        let closeRect = CGRect(
            x: pillRect.maxX - closeSize - Self.tabCloseTrailingGap, y: midY - closeSize / 2,
            width: closeSize, height: closeSize)

        // Activity dot — shown on inactive tabs when a command finished in
        // background; a trigger's mark shows in the warning color. It shares
        // the close slot, and the ✕ replaces it on hover.
        if showDot {
            let dotSize = WorkspacePillStyle.activityDotSize
            let dotColor =
                agentInSlot ? agentColor : tab.state.triggerMark != nil ? theme.warning : theme.accentEmphasis
            ctx.setFillColor((dotColor ?? theme.accentEmphasis).cgColor)
            ctx.fillEllipse(
                in: CGRect(
                    x: closeRect.midX - dotSize / 2, y: closeRect.midY - dotSize / 2,
                    width: dotSize, height: dotSize))
        }

        // Close button — only show on active or hovered tab
        if showClose {
            WorkspacePillStyle.drawCloseButton(
                ctx, in: closeRect, tint: theme.chromeMuted, hovered: isHovered && isCloseButtonHovered)
        }
    }

    /// The agent's state color while it works or waits for the user (a question,
    /// an error, an unread answer); nil for a read answer or no agent, so a
    /// finished tab stays quiet. Same colors as the vertical tabs and status bar.
    static func agentBadgeColor(for item: AgentInbox.Item?, theme: TerminalTheme) -> NSColor? {
        guard let item, item.state == .working || item.needsAttention else { return nil }
        return AgentInboxSegment.color(for: item, theme: theme)
    }

    /// A dot on the icon tile's top-right corner, ringed in the bar color so it
    /// reads over the tile.
    static func drawAgentBadge(_ ctx: CGContext, color: NSColor, theme: TerminalTheme, tileCorner: CGPoint) {
        let size: CGFloat = 7
        let rect = CGRect(x: tileCorner.x - size + 1.5, y: tileCorner.y - 1.5, width: size, height: size)
        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
    }

    /// Red dot on the pill's top-left corner while the tab records.
    static func drawRecordingDot(_ ctx: CGContext, in pill: CGRect) {
        let size: CGFloat = 6
        ctx.setFillColor(AppSettings.shared.theme.error.cgColor)
        ctx.fillEllipse(in: CGRect(x: pill.minX + 3, y: pill.minY + 3, width: size, height: size))
    }

    /// Marks tabs that show a tmux pane, and tmux in menus.
    static let tmuxSymbol = "rectangle.split.3x1"

    /// A plugin tab's own icon (review, diff, timeline), else its content type's.
    static func tabSymbolName(_ tab: Pane.Tab) -> String {
        if case .pluginView(let state) = tab.state.contentState { return state.iconSymbol }
        return tab.contentType.symbolName
    }

    func drawLeadingIcon(tab: Pane.Tab, theme: TerminalTheme, x: CGFloat, midY: CGFloat, isActive: Bool) -> CGFloat {
        // The tile starts closer to the pill edge than the title would; `x` is
        // where the title would start without an icon.
        let tile = Self.iconTileRect(pillMinX: x - Self.tabTextLeadIn, midY: midY)
        let x = tile.midX - 7
        // Content type icon for non-terminal tabs
        if tab.contentType != .terminal {
            let iconColor = isActive ? theme.chromeText : theme.chromeMuted
            Self.drawIconTile(tile, color: iconColor, isActive: isActive)
            guard
                let drawn = Self.drawTabIcon(
                    symbolName: Self.tabSymbolName(tab), color: iconColor, x: x, midY: midY, isActive: isActive)
            else { return 0 }
            drawn.draw()
            return drawn.width
        }

        // Process icon (when a non-shell process is running) — terminal tabs only.
        // Gated on the same predicate `measuredTabWidth` uses to reserve the space.
        guard tabHasLeadingIcon(tab) else { return 0 }
        // A tmux pane: its foreground process is Boo's bridge, so mark it as tmux.
        if pane.tmuxOwned {
            let color = WorkspaceColor.green.themed(theme) ?? theme.chromeText
            Self.drawIconTile(tile, color: color, isActive: isActive)
            guard
                let drawn = Self.drawTabIcon(
                    symbolName: Self.tmuxSymbol, color: color, x: x, midY: midY, isActive: isActive)
            else { return 0 }
            drawn.draw()
            return drawn.width
        }
        let process = tab.state.foregroundProcess
        let iconColor = ProcessIcon.themeColor(for: process, theme: theme, isActive: isActive)
        let iconSize: CGFloat = 14
        let opacity: CGFloat = isActive ? 1.0 : 0.7
        Self.drawIconTile(tile, color: iconColor, isActive: isActive)
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
        return localDisplayPath(tab.workingDirectory) ?? "shell"
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

    /// Rounded square behind a tab icon, tinted with the icon's own colour.
    /// The leading icon tile of a tab pill starting at `pillMinX`.
    static func iconTileRect(pillMinX: CGFloat, midY: CGFloat) -> CGRect {
        CGRect(
            x: pillMinX + tabIconTileInset, y: midY - tabIconTileSize / 2, width: tabIconTileSize,
            height: tabIconTileSize)
    }

    static func drawIconTile(_ rect: CGRect, color: NSColor, isActive: Bool) {
        color.withAlphaComponent(isActive ? 0.22 : 0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// Dimmed text after the title: the working directory when the title shows
    /// a running process, so the tab says what runs and where. Nil otherwise.
    static func tabDisplaySubtitle(tab: Pane.Tab) -> String? {
        // A browser an agent opened names that agent: "Example Domain  t7".
        if tab.contentType == .browser { return AgentBrowser.ownerHandle(of: tab.id) }
        guard tab.contentType == .terminal, tab.remoteSession == nil else { return nil }
        let process = tab.state.foregroundProcess
        guard !process.isEmpty, !ProcessIcon.isShell(process) else { return nil }
        return localDisplayPath(tab.workingDirectory)
    }

    /// Tilde-contracted local path, nil when empty.
    static func localDisplayPath(_ dir: String) -> String? {
        guard !dir.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }

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
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let configured = iconImage.withSymbolConfiguration(config) ?? iconImage
        let iconSize: CGFloat = 14
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
        addNewTabItems(to: menu)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// One "New <Type> Tab" item per creatable content type, then the agents.
    func addNewTabItems(to menu: NSMenu) {
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
        menu.addSection(AgentMenuItems.newTabItems(paneID: paneID))
    }

    @objc private func newTabMenuAction(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? ContentType else { return }
        addNewTab(contentType: type, workingDirectory: pane.activeTab?.workingDirectory ?? "~", group: activeGroupID)
    }
}
