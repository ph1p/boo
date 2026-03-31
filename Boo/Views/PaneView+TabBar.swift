import Cocoa

extension PaneView {

    // MARK: - Tab Bar Drawing

    func drawTabsScrollable(ctx: CGContext, theme: TerminalTheme, barH: CGFloat, termBgColor: CGColor) {
        let widths = allTabWidths()
        let totalW = widths.reduce(0, +) + plusButtonWidth
        let maxScroll = max(0, totalW - bounds.width)
        let isOverflowing = maxScroll > 0

        // Clamp and auto-scroll to active tab only when active tab changes
        tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        if isOverflowing && pane.activeTabIndex != lastAutoScrolledTabIndex {
            lastAutoScrolledTabIndex = pane.activeTabIndex
            let clipW = bounds.width - plusButtonWidth
            // Compute active tab position
            var activeStart: CGFloat = 0
            for i in 0..<pane.activeTabIndex { activeStart += widths[i] }
            activeStart -= tabScrollOffset
            let activeEnd = activeStart + widths[pane.activeTabIndex]
            if activeStart < 0 {
                tabScrollOffset += activeStart
            } else if activeEnd > clipW {
                tabScrollOffset += activeEnd - clipW
            }
            tabScrollOffset = min(max(0, tabScrollOffset), maxScroll)
        } else if !isOverflowing {
            tabScrollOffset = 0
        }

        // Clip scrollable tabs so they don't draw over the pinned plus button
        let clipW = bounds.width - plusButtonWidth
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: clipW, height: barH + 1))

        var x: CGFloat = -tabScrollOffset
        for (i, tab) in pane.tabs.enumerated() {
            let isActive = i == pane.activeTabIndex
            drawSingleTab(
                ctx: ctx, theme: theme, tab: tab, index: i, x: x, y: 0,
                width: widths[i], rowH: barH, isActive: isActive, termBgColor: termBgColor)
            x += widths[i]
        }

        ctx.restoreGState()

        // Plus button: always pinned at right edge in scroll mode
        let pinX = bounds.width - plusButtonWidth
        drawPlusButton(ctx: ctx, theme: theme, x: pinX, y: 0, width: plusButtonWidth, rowH: barH)
    }

    func drawTabsWrapped(ctx: CGContext, theme: TerminalTheme, barH: CGFloat, termBgColor: CGColor) {
        tabScrollOffset = 0
        let layouts = wrapLayout()

        for (i, tab) in pane.tabs.enumerated() {
            guard i < layouts.count else { break }
            let lay = layouts[i]
            let isActive = i == pane.activeTabIndex
            drawSingleTab(
                ctx: ctx, theme: theme, tab: tab, index: i, x: lay.x, y: lay.y,
                width: lay.width, rowH: singleRowTabHeight, isActive: isActive, termBgColor: termBgColor)
        }

        // Plus button after last tab layout
        let lastLay = layouts.last
        let plusX = (lastLay?.x ?? 0) + (lastLay?.width ?? 0)
        let plusY = lastLay?.y ?? 0
        let availW = bounds.width
        if plusX + plusButtonWidth > availW && plusX > 0 {
            drawPlusButton(
                ctx: ctx, theme: theme, x: 0, y: plusY + singleRowTabHeight, width: plusButtonWidth,
                rowH: singleRowTabHeight)
        } else {
            drawPlusButton(ctx: ctx, theme: theme, x: plusX, y: plusY, width: plusButtonWidth, rowH: singleRowTabHeight)
        }
    }

    func drawSingleTab(
        ctx: CGContext, theme: TerminalTheme, tab: Pane.Tab, index: Int, x: CGFloat, y: CGFloat,
        width: CGFloat, rowH: CGFloat, isActive: Bool, termBgColor: CGColor
    ) {
        let tabRect = CGRect(x: x, y: y, width: width, height: rowH)
        let isHovered = hoveredTabIndex == index

        if isActive {
            ctx.setFillColor(termBgColor)
            ctx.fill(tabRect)
        } else if isHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.08).cgColor)
            ctx.fill(tabRect)
        }

        // Full-height vertical separators (same color as bottom border)
        let midY = y + rowH / 2
        if x > 0 {
            ctx.setFillColor(theme.chromeBorder.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 0.5, height: rowH))
        }
        // Right edge separator on the last tab
        if index == pane.tabs.count - 1 {
            ctx.setFillColor(theme.chromeBorder.cgColor)
            ctx.fill(CGRect(x: x + width - 0.5, y: y, width: 0.5, height: rowH))
        }

        var textX = x + 10

        // Close button visible on hover or active tab (when closeable)
        let showClose = showTabClose && (isActive || isHovered)
        let closeZone: CGFloat = showClose ? 18 : 8

        // Process icon (when a non-shell process is running)
        let process = tab.state.foregroundProcess
        if !process.isEmpty, !ProcessIcon.isShell(process),
            let iconName = ProcessIcon.icon(for: process)
        {
            let iconColor = ProcessIcon.themeColor(for: process, theme: theme, isActive: isActive)
            let iconImage = NSImage(
                systemSymbolName: iconName, accessibilityDescription: process)
            if let iconImage {
                let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                let configured = iconImage.withSymbolConfiguration(config) ?? iconImage
                let iconSize: CGFloat = 12
                let iconRect = CGRect(x: textX, y: midY - iconSize / 2, width: iconSize, height: iconSize)
                // Tint the SF Symbol by drawing it as a template with the desired color
                let tinted = NSImage(size: configured.size)
                tinted.lockFocus()
                iconColor.set()
                let imageRect = NSRect(origin: .zero, size: configured.size)
                configured.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                imageRect.fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(
                    in: iconRect, from: .zero, operation: .sourceOver,
                    fraction: isActive ? 1.0 : 0.7)
                textX += iconSize + 3
            }
        }

        // Title — use truncating tail paragraph style for automatic ellipsis
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: isActive ? .medium : .regular),
            .foregroundColor: isActive
                ? theme.chromeText : (isHovered ? theme.chromeText.withAlphaComponent(0.8) : theme.chromeMuted),
            .paragraphStyle: para
        ]
        let title = Self.tabDisplayTitle(tab: tab) as NSString
        let titleSize = title.size(withAttributes: attrs)
        let maxTitleW = max(0, x + width - textX - closeZone)
        title.draw(
            in: CGRect(
                x: textX, y: midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW), height: titleSize.height),
            withAttributes: attrs)

        // Close button — only show on active or hovered tab
        if showClose {
            let closeHovered = isHovered && isCloseButtonHovered
            let closeAlpha: CGFloat = closeHovered ? 0.9 : (isActive ? 0.7 : 0.5)

            let circleSize: CGFloat = 16
            let circleCenterX = x + width - circleSize / 2 - 4
            let circleCenterY = midY

            // Subtle circular background on close-button hover
            if closeHovered {
                let circleX = circleCenterX - circleSize / 2
                let circleY = circleCenterY - circleSize / 2
                ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.15).cgColor)
                ctx.fillEllipse(in: CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
            }

            let ca: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: theme.chromeMuted.withAlphaComponent(closeAlpha)
            ]
            let cs = "\u{2715}" as NSString
            let csz = cs.size(withAttributes: ca)
            cs.draw(
                at: NSPoint(x: circleCenterX - csz.width / 2, y: circleCenterY - csz.height / 2), withAttributes: ca)
        }
    }

    func drawPlusButton(ctx: CGContext, theme: TerminalTheme, x: CGFloat, y: CGFloat, width: CGFloat, rowH: CGFloat) {
        // Background
        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(CGRect(x: x, y: y, width: width, height: rowH))

        // Hover highlight
        if isPlusButtonHovered {
            ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.1).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: width, height: rowH))
        }

        // Full-height left separator
        ctx.setFillColor(theme.chromeBorder.cgColor)
        ctx.fill(CGRect(x: x, y: y, width: 1, height: rowH))

        // "+" centered — adjust for descender so the visible glyph is vertically centered
        let font = NSFont.systemFont(ofSize: 15, weight: .light)
        let color = theme.chromeMuted.withAlphaComponent(isPlusButtonHovered ? 0.9 : 0.6)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let plusStr = "+" as NSString
        let plusSize = plusStr.size(withAttributes: attrs)
        let contentX = x + 1
        let contentW = width - 1
        let midY = y + rowH / 2
        // In flipped view, draw(at:) y is top of text box. Text box = ascender + descender.
        // Visual center of "+" is at ascender/2 from top. We want that at midY.
        let drawY = midY - font.ascender / 2 - 4
        plusStr.draw(
            at: NSPoint(x: contentX + (contentW - plusSize.width) / 2, y: drawY),
            withAttributes: attrs)
    }

    // MARK: - Tab Display Helpers

    static func tabDisplayTitle(tab: Pane.Tab) -> String {
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
        // Extract user from session host (e.g. "root@host" -> "root", alias "het" -> nil)
        var user: String?
        if let session = tab.remoteSession {
            let host = session.displayName
            if host.contains("@") {
                user = host.split(separator: "@").first.map(String.init)
            }
        }
        // Also try extracting user from the terminal title ("root@host:~")
        if user == nil {
            let title = tab.title.trimmingCharacters(in: .whitespaces)
            if let atIdx = title.firstIndex(of: "@") {
                user = String(title[..<atIdx])
            }
        }
        // Contract known home directories
        let homes = ["/root", user.map { "/home/\($0)" }].compactMap { $0 }
        for home in homes {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
        }
        return path
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
}
