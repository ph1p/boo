import Cocoa

extension PaneView {

    // MARK: - Font Cache

    private enum TabFonts {
        nonisolated(unsafe) static let title10Regular = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        nonisolated(unsafe) static let title10Medium = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        nonisolated(unsafe) static let close8Bold = NSFont.systemFont(ofSize: 8, weight: .bold)
        nonisolated(unsafe) static let plus15Light = NSFont.systemFont(ofSize: 15, weight: .light)
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

        ctx.restoreGState()

        let plusSlot = plusButtonSlot(widths: widths)
        drawPlusButton(
            ctx: ctx, theme: theme, x: plusSlot.minX, y: plusSlot.minY, width: plusSlot.width, rowH: plusSlot.height)
    }

    func drawTabsWrapped(ctx: CGContext, theme: TerminalTheme) {
        tabScrollOffset = 0
        let widths = allTabWidths()
        let layouts = wrapLayout(widths: widths)

        for (i, tab) in pane.tabs.enumerated() {
            guard i < layouts.count else { break }
            let lay = layouts[i]
            let isActive = i == pane.activeTabIndex
            drawSingleTab(
                ctx: ctx, theme: theme, tab: tab, index: i, x: lay.x, y: lay.y,
                width: lay.width, rowH: singleRowTabHeight, isActive: isActive)
        }

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
        let tabRect = CGRect(x: x, y: y, width: width, height: rowH)
        let isHovered = hoveredTabIndex == index

        // Pill inside the tab slot — the horizontal inset supplies the gap between
        // neighbouring pills, the vertical one keeps the pill off the bar edges.
        let pillRect = Self.tabPillRect(inSlot: tabRect)
        WorkspacePillStyle.fill(
            ctx, rect: pillRect, active: isActive, hovered: isHovered,
            wsColor: nil, neutral: theme.chromeMuted)

        let midY = y + rowH / 2
        var textX = pillRect.minX + Self.tabTextLeadIn

        // Close button visible on hover or active tab (when closeable)
        let showClose = showTabClose && (isActive || isHovered)
        let closeZone: CGFloat = showClose ? 18 : 8

        // Content type icon for non-terminal tabs
        if tab.contentType != .terminal {
            let iconColor = isActive ? theme.chromeText : theme.chromeMuted
            if let drawn = Self.drawTabIcon(
                symbolName: tab.contentType.symbolName, color: iconColor,
                x: textX, midY: midY, isActive: isActive
            ) {
                drawn.draw()
                textX += drawn.width
            }
        }

        // Process icon (when a non-shell process is running) — terminal tabs only.
        // Gated on the same predicate `measuredTabWidth` uses to reserve the space.
        let process = tab.state.foregroundProcess
        if tab.contentType == .terminal, tabHasLeadingIcon(tab) {
            let iconColor = ProcessIcon.themeColor(for: process, theme: theme, isActive: isActive)
            let iconSize: CGFloat = 12
            let opacity: CGFloat = isActive ? 1.0 : 0.7
            if let customImg = ProcessIcon.customImage(for: process, color: iconColor, size: iconSize) {
                let iconRect = CGRect(x: textX, y: midY - iconSize / 2, width: iconSize, height: iconSize)
                customImg.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: opacity)
                textX += Self.tabIconAdvance
            } else if let iconName = ProcessIcon.icon(for: process),
                let drawn = Self.drawTabIcon(
                    symbolName: iconName, color: iconColor,
                    x: textX, midY: midY, isActive: isActive
                )
            {
                drawn.draw()
                textX += drawn.width
            }
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
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let titleSize = title.size(withAttributes: attrs)
        let maxTitleW = max(0, pillRect.maxX - textX - closeZone)
        title.draw(
            in: CGRect(
                x: textX, y: midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW), height: titleSize.height),
            withAttributes: attrs)

        // Activity dot — shown on inactive tabs when a command finished in background
        if tab.state.hasActivity && !isActive {
            let dotSize: CGFloat = 5
            ctx.setFillColor(theme.accentColor.withAlphaComponent(0.85).cgColor)
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
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.15).cgColor)
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
        addNewTab(contentType: type, workingDirectory: pane.activeTab?.workingDirectory ?? "~")
    }
}
